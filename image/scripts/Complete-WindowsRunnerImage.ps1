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

function Get-WindowsBuildKeyPath {
    param([Parameter(Mandatory)] $Identity)
    if ($Identity.provider -cne 'Microsoft Software Key Storage Provider' -or -not $Identity.machineKey -or
        $Identity.thumbprint -cnotmatch '^[A-Fa-f0-9]{40}$' -or [string]::IsNullOrWhiteSpace($Identity.keyName) -or
        $Identity.uniqueName -cnotmatch '^[A-Za-z0-9_-]+$') { throw 'Unexpected build certificate key identity' }
    return Join-Path "$env:ProgramData\Microsoft\Crypto\Keys" $Identity.uniqueName
}

function Get-WindowsBuildKeyFile {
    param([Parameter(Mandatory)] $Identity)
    $path = Get-WindowsBuildKeyPath -Identity $Identity
    # File.Exists/Test-Path can hide access failures. Enumerate the known parent
    # with terminating errors, and inspect only the recorded software-KSP file.
    $files = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Force -ErrorAction Stop | Where-Object { $_.Name -ieq $Identity.uniqueName })
    if ($files.Count -gt 1 -or ($files.Count -eq 1 -and ($files[0].PSIsContainer -or ($files[0].Attributes -band [IO.FileAttributes]::ReparsePoint)))) { throw 'Unexpected build key filesystem entry' }
    if ($files.Count -eq 1) { return $files[0] }
}

function Test-WindowsBuildCngKey {
    param([Parameter(Mandatory)] $Identity)
    $null = Get-WindowsBuildKeyPath -Identity $Identity
    return [Security.Cryptography.CngKey]::Exists($Identity.keyName, [Security.Cryptography.CngProvider]::MicrosoftSoftwareKeyStorageProvider, [Security.Cryptography.CngKeyOpenOptions]::MachineKey)
}

function Get-WindowsImageBuildCertificate {
    $certificates = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object { $_.FriendlyName -eq 'GitHubRunnerPackerWinRM' })
    if ($certificates.Count -ne 1) { throw 'Expected exactly one owned build certificate' }
    $certificate = $certificates[0]
    $rsa = $null
    try {
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
        if ($rsa -isnot [Security.Cryptography.RSACng]) { throw 'Build certificate is not backed by RSA CNG' }
        $key = $rsa.Key
        $identity = [pscustomobject]@{ thumbprint = $certificate.Thumbprint; provider = $key.Provider.Provider; machineKey = $key.IsMachineKey; keyName = $key.KeyName; uniqueName = $key.UniqueName; key = $key; rsa = $rsa }
        if (-not (Get-WindowsBuildKeyFile -Identity $identity) -or -not (Test-WindowsBuildCngKey -Identity $identity)) { throw 'Build key cannot be proven present before Sysprep' }
        $listeners = @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop | ForEach-Object { (Get-Item ($_.PSPath + '\CertificateThumbprint') -ErrorAction Stop).Value } | Where-Object { $_ })
        if ($listeners.Count -ne 1 -or $listeners[0] -ine $identity.thumbprint) { throw 'WinRM does not reference the owned build certificate' }
        Write-Host 'Build TLS preflight: owned software-CNG machine key and exact backing file are present.'
        # Keep this owned handle alive in the finalizer process across Sysprep.
        # No private-key bytes are exported, serialized, logged, or transmitted.
        return $identity
    } catch {
        if ($null -ne $rsa) { $rsa.Dispose() }
        throw
    }
}

function Remove-WindowsImageBuildCertificate {
    param([Parameter(Mandatory)] $Identity)
    $keyPath = Get-WindowsBuildKeyPath -Identity $Identity
    try {
        $providerPresent = Test-WindowsBuildCngKey -Identity $Identity
        $filePresent = $null -ne (Get-WindowsBuildKeyFile -Identity $Identity)
        Write-Host "Build TLS after Sysprep: providerPresent=$providerPresent; filePresent=$filePresent"
        if ($providerPresent) { $Identity.key.Delete() }
    } finally {
        $Identity.rsa.Dispose()
    }
    if (Test-WindowsBuildCngKey -Identity $Identity) { throw 'Build key remains available from its provider' }
    # An orphaned backing file is still private-key material. After the provider
    # reports absence, delete only the filename identified before generalization.
    if (Get-WindowsBuildKeyFile -Identity $Identity) { Remove-Item -LiteralPath $keyPath -Force -ErrorAction Stop }
    if ((Test-WindowsBuildCngKey -Identity $Identity) -or (Get-WindowsBuildKeyFile -Identity $Identity)) { throw 'Build private-key absence could not be verified' }
    # Remove the public certificate only after independent key-absence proof.
    # Certificate-provider -DeleteKey removes the certificate before deleting
    # its key, so certificate disappearance alone is not successful cleanup.
    $certificate = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object { $_.Thumbprint -ieq $Identity.thumbprint })
    if ($certificate.Count) { Remove-Item -Path "Cert:\LocalMachine\My\$($Identity.thumbprint)" -Force -ErrorAction Stop }
    if (@(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object { $_.Thumbprint -ieq $Identity.thumbprint -or $_.FriendlyName -eq 'GitHubRunnerPackerWinRM' }).Count) { throw 'Build certificate remains after cleanup' }
    Write-Host 'Build TLS cleanup verified: provider key, exact backing file, and owned certificate are absent.'
    return @{ privateKeyAbsent = $true; certificateAbsent = $true }
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
$buildCertificate = Get-WindowsImageBuildCertificate
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
# Remove the recorded build key before changing the account context. Sysprep can
# change key availability; no missing-key or access error is assumed successful.
$certificateCleanup = Remove-WindowsImageBuildCertificate -Identity $buildCertificate
# Retire the identity only after Sysprep polling, before the final command exits.
# The Packer communicator must still receive success; disconnects remain fatal.
$accountCleanup = Remove-WindowsImageBuildAccount -Expected $buildAccount
Assert-WindowsImageAccountCleanup -Cleanup $accountCleanup -GeneralizationState (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
$manifest | Add-Member -NotePropertyName imageAccountCleanup -NotePropertyValue @{ mode = $accountCleanup.mode; sysprepState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'; serverSysprepCompleted = $true; buildAccountAbsent = $true } -Force
$manifest | Add-Member -NotePropertyName imageCertificateCleanup -NotePropertyValue $certificateCleanup -Force
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stateRoot 'manifest.json')
Write-Host "Image build account retired; mode: $($accountCleanup.mode); Server Sysprep completed."

# No later remote cleanup command is needed, but the current WinRM command must
# still return successfully. A disconnect remains fatal to the Packer build.
Get-ChildItem WSMan:\localhost\Listener | Remove-Item -Recurse -Force
Get-NetFirewallRule -Name 'WINRM-Packer-Build' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 0 -Force | Out-Null
Remove-Item -LiteralPath $PSCommandPath -Force
