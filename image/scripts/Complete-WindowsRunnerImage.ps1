[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WindowsImageBuildAccount {
    # Server Sysprep clears the built-in administrator password; client editions
    # do not have that contract and are not supported by this image recipe.
    if ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 3) { throw 'Image account cleanup requires Windows Server' }
    $users = @(Get-LocalUser -ErrorAction Stop)
    $account = @($users | Where-Object { $_.Name -ieq 'packer' })
    if ($account.Count -ne 1) { throw 'Expected exactly one image build account' }
    $account = $account[0]
    $sid = $account.SID.Value
    if ($sid -cmatch '^S-1-5-21-\d+-\d+-\d+-(\d+)$') { $rid = [uint32] $Matches[1] }
    else { throw 'Unexpected image build account SID' }
    Write-Host "Image build account SID: $sid; RID: $rid"
    if ($rid -eq 500) {
        if (@($users | Where-Object { $_.Name -ieq 'Administrator' -and $_.SID.Value -ne $sid }).Count) { throw 'Administrator name is owned by a different account' }
        $mode = 'BuiltinAdministrator'
    } elseif ($rid -ge 1000) { $mode = 'RemovedLocalUser' }
    else { throw 'Unsupported built-in image build account' }
    return [pscustomobject]@{ mode = $mode; sid = $sid }
}

function Remove-WindowsImageBuildAccount {
    param([Parameter(Mandatory)] $Expected)
    $users = @(Get-LocalUser -ErrorAction Stop)
    $mode = $Expected.mode
    if ($mode -eq 'BuiltinAdministrator') {
        $account = @($users | Where-Object { $_.SID.Value -cmatch '^S-1-5-21-\d+-\d+-\d+-500$' })
        if ($account.Count -ne 1 -or $account[0].Name -inotmatch '^(packer|Administrator)$') { throw 'Unexpected built-in administrator after Sysprep' }
        $account = $account[0]
        $sid = $account.SID.Value
        if ($sid -cne $Expected.sid) { throw 'Image build account SID changed before capture' }
        if (@($users | Where-Object { $_.Name -ieq 'Administrator' -and $_.SID.Value -ne $sid }).Count) { throw 'Administrator name is owned by a different account' }
        # Azure renames RID500 to adminUsername during provisioning. It cannot
        # be deleted; restore its image name and revoke access after Sysprep.
        if ($account.Name -cne 'Administrator') { Rename-LocalUser -SID $account.SID -NewName 'Administrator' -ErrorAction Stop }
        Disable-LocalUser -SID $account.SID -ErrorAction Stop
        $retired = Get-LocalUser -SID $account.SID -ErrorAction Stop
        if ($retired.Name -cne 'Administrator' -or $retired.Enabled) { throw 'Built-in image administrator was not retired' }
    } elseif ($mode -eq 'RemovedLocalUser') {
        $account = @($users | Where-Object { $_.SID.Value -eq $Expected.sid -and $_.Name -ieq 'packer' })
        if ($account.Count -ne 1) { throw 'Unexpected ordinary build account after Sysprep' }
        $account = $account[0]
        $sid = $account.SID.Value
        Remove-LocalUser -SID $account.SID -ErrorAction Stop
    } else { throw 'Unknown image build account cleanup mode' }
    $remaining = @(Get-LocalUser -ErrorAction Stop)
    if (@($remaining | Where-Object { $_.Name -ieq 'packer' -or ($mode -eq 'RemovedLocalUser' -and $_.SID.Value -eq $sid) }).Count) { throw 'Image build account cleanup failed' }
    return [pscustomobject]@{ mode = $mode; sid = $sid }
}

function Assert-WindowsImageAccountCleanup {
    param([Parameter(Mandatory)] $Cleanup, [Parameter(Mandatory)][string] $GeneralizationState)
    if ($GeneralizationState -cne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw 'Account cleanup requires completed Server Sysprep' }
    $users = @(Get-LocalUser -ErrorAction Stop)
    if (@($users | Where-Object { $_.Name -ieq 'packer' }).Count) { throw 'Image still contains its build account name' }
    if ($Cleanup.mode -eq 'BuiltinAdministrator') {
        $administrator = @($users | Where-Object { $_.SID.Value -cmatch '^S-1-5-21-\d+-\d+-\d+-500$' })
        if ($administrator.Count -ne 1 -or $administrator[0].Name -cne 'Administrator' -or $administrator[0].Enabled) { throw 'Generalized image administrator must remain disabled' }
        Write-Host "Image account readback: SID=$($administrator[0].SID.Value); name=$($administrator[0].Name); enabled=$($administrator[0].Enabled)"
    } elseif ($Cleanup.mode -eq 'RemovedLocalUser') {
        if (@($users | Where-Object { $_.SID.Value -eq $Cleanup.sid }).Count) { throw 'Deleted image build account remains' }
    } else { throw 'Unknown image build account cleanup mode' }
}

# Tests load only the account-cleanup functions, without preparing the host.
if ($MyInvocation.InvocationName -eq '.') { return }

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
# Record the identity before generalization. No new password is generated,
# read, or transmitted; Server Sysprep clears the built-in password.
$buildAccount = Get-WindowsImageBuildAccount
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
# Retire the identity only after Sysprep polling, before the final command exits.
# The Packer communicator must still receive success; disconnects remain fatal.
$accountCleanup = Remove-WindowsImageBuildAccount -Expected $buildAccount
Assert-WindowsImageAccountCleanup -Cleanup $accountCleanup -GeneralizationState (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
$manifest | Add-Member -NotePropertyName imageAccountCleanup -NotePropertyValue @{ mode = $accountCleanup.mode; sysprepState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'; serverSysprepCompleted = $true; buildAccountAbsent = $true } -Force
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stateRoot 'manifest.json')
Write-Host "Image build account retired; mode: $($accountCleanup.mode); Server Sysprep completed."

# The final remote command is already authenticated; remove build-only TLS
# private keys and listeners before capture. skip_clean prevents a later remote
# cleanup connection. The final script contains no secrets and removes itself.
$thumbprints = @(Get-ChildItem WSMan:\localhost\Listener | ForEach-Object { (Get-Item ($_.PSPath + '\CertificateThumbprint') -ErrorAction SilentlyContinue).Value } | Where-Object { $_ })
foreach ($thumbprint in $thumbprints) {
    $certificate = "Cert:\LocalMachine\My\$thumbprint"
    if (Test-Path $certificate) { Remove-Item -Path $certificate -DeleteKey -Force }
}
# Sysprep may reset the listener; still remove the guest-created build key.
foreach ($buildCertificate in Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'GitHubRunnerPackerWinRM' }) {
    Remove-Item -Path "Cert:\LocalMachine\My\$($buildCertificate.Thumbprint)" -DeleteKey -Force
}
if (@(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'GitHubRunnerPackerWinRM' }).Count) { throw 'Build TLS key remains in the image' }
Get-ChildItem WSMan:\localhost\Listener | Remove-Item -Recurse -Force
Get-NetFirewallRule -Name 'WINRM-Packer-Build' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 0 -Force | Out-Null
Remove-Item -LiteralPath $PSCommandPath -Force
