[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stateRoot = "$env:ProgramData\GitHubRunner"
$runnerRoot = "$env:SystemDrive\actions-runner"
$manifest = Get-Content -LiteralPath (Join-Path $stateRoot 'manifest.json') -Raw | ConvertFrom-Json
foreach ($probe in @(
    @{ command = 'dotnet'; args = @('--version'); expected = '^10\.0\.401$' },
    @{ command = 'node'; args = @('--version'); expected = '^v24\.21\.0$' },
    @{ command = 'git'; args = @('--version'); expected = '2\.56\.0' },
    @{ command = 'pwsh'; args = @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()'); expected = '^7\.6\.6$' },
    @{ command = "$runnerRoot\bin\Runner.Listener.exe"; args = @('--version'); expected = ('^' + [regex]::Escape($manifest.runnerVersion) + '$') }
)) {
    $output = & $probe.command @($probe.args)
    if ($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch $probe.expected) { throw "Image probe failed: $($probe.command)" }
}
if ((Get-PSDrive C).Free -lt 15GB) { throw 'P10 image requires at least 15 GiB free after tool installation' }
if ((Test-Path "$runnerRoot\.runner") -or (Test-Path "$stateRoot\started") -or (Test-Path "$env:SystemDrive\AzureData\CustomData.bin")) { throw 'Image must not contain registration, JIT, or one-shot runtime state' }

# Jobs use SYSTEM in a disposable VM. No interactive desktop session is provided.
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoLogo -NoProfile -NonInteractive -File `"$stateRoot\Start-WindowsRunner.ps1`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName 'GitHubEphemeralRunner' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
# Images are refreshed for security patches; update scans must not interrupt jobs.
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -PropertyType DWord -Value 1 -Force | Out-Null
# Remove the build account. The current final provisioning process keeps its
# token until exit; no further WinRM connection is used after this step.
Remove-LocalUser -Name 'packer'
foreach ($service in Get-Service -Name RdAgent, WindowsAzureGuestAgent -ErrorAction Stop) {
    if ($service.Status -ne 'Running') { throw "Azure guest agent is not ready: $($service.Name)" }
}
& "$env:SystemRoot\System32\Sysprep\Sysprep.exe" /oobe /generalize /quiet /quit /mode:vm
if ($LASTEXITCODE -ne 0) { throw 'Sysprep failed' }
$deadline = [DateTime]::UtcNow.AddMinutes(15)
while ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'Sysprep timed out' }
    Start-Sleep -Seconds 10
}

# The final remote command is already authenticated; remove build-only TLS
# private keys and listeners before capture. skip_clean prevents a later remote
# cleanup connection. The final script contains no secrets and removes itself.
$thumbprints = @(Get-ChildItem WSMan:\localhost\Listener | ForEach-Object { (Get-Item ($_.PSPath + '\CertificateThumbprint') -ErrorAction SilentlyContinue).Value } | Where-Object { $_ })
foreach ($thumbprint in $thumbprints) {
    $certificate = "Cert:\LocalMachine\My\$thumbprint"
    if (Test-Path $certificate) { Remove-Item $certificate -DeleteKey -Force }
}
# Sysprep may reset the listener; still remove the guest-created build key.
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'GitHubRunnerPackerWinRM' } | Remove-Item -DeleteKey -Force
if (@(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'GitHubRunnerPackerWinRM' }).Count) { throw 'Build TLS key remains in the image' }
Get-ChildItem WSMan:\localhost\Listener | Remove-Item -Recurse -Force
Get-NetFirewallRule -Name 'WINRM-Packer-Build' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 0 -Force | Out-Null
Remove-Item -LiteralPath $PSCommandPath -Force
