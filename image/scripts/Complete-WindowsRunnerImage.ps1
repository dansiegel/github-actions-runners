[CmdletBinding()]
param([string] $AttemptId, [string] $ExpectedScriptSHA256, [switch] $RegisterTask, [switch] $AllowTemporaryBatchLogonAssignment)
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
        if ($administrator.Count -ne 1 -or $administrator[0].Name -cne 'Administrator' -or $administrator[0].SID.Value -cne $Cleanup.sid -or $administrator[0].Enabled) { throw 'Generalized image administrator must remain disabled' }
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

function Start-WindowsImageFinalizationAttempt {
    param([string] $Root, [string] $Attempt, [string] $SourceSHA256, [string] $SourcePath, [string] $ExecutionSID)
    if ($Attempt -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' -or $SourceSHA256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid finalization identity' }
    if ((Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $SourceSHA256) { throw 'Finalizer source changed after staging' }
    # CreateNew is atomic. Even a failed attempt keeps this marker, so neither a
    # replay nor another command identity can run Sysprep twice on this builder.
    $stream = [IO.File]::Open((Join-Path $Root 'image-finalization.started.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((@{ attemptId = $Attempt; scriptSHA256 = $SourceSHA256; executionSID = $ExecutionSID } | ConvertTo-Json -Compress))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } finally { $stream.Dispose() }
}


function Get-WindowsFinalizationTaskProperty {
    param($Object, [string] $Name)
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
}

function Resolve-WindowsFinalizationTaskSID {
    param([string] $UserId)
    if ([string]::IsNullOrWhiteSpace($UserId)) { throw 'Principal.UserId is empty' }
    if ($UserId -cmatch '^S-1-\d+(-\d+)+$') { return ([Security.Principal.SecurityIdentifier]::new($UserId)).Value }
    # Task Scheduler can return an account name even when registered with a SID.
    # Resolve through Windows and compare the immutable SID, never the name.
    return ([Security.Principal.NTAccount]::new($UserId)).Translate([Security.Principal.SecurityIdentifier]).Value
}

function Format-WindowsFinalizationTaskValue {
    param($Value)
    if ($null -eq $Value) { return '<missing>' }
    $text = [string]$Value
    # Only bounded enum/duration/number values enter diagnostics. Never include
    # action arguments, arbitrary paths, account names, or raw task XML.
    $knownEnum = $text -in @('S4U', 'Password', 'InteractiveToken', 'ServiceAccount', 'Highest', 'HighestAvailable', 'Limited', 'LeastPrivilege', 'IgnoreNew', 'Parallel', 'Queue', 'StopExisting', 'True', 'False')
    if ($text.Length -gt 64 -or (-not $knownEnum -and $text -cnotmatch '^-?\d+$' -and $text -cnotmatch '^P[0-9TYMDHS.+-]+$')) { $text = '<unrecognized>' }
    return "$text [$($Value.GetType().Name)]"
}

function Assert-WindowsImageFinalizationTask {
    param($Task, [string] $ExpectedSID, [string] $SourcePath, [string] $Attempt, [string] $SourceSHA256)
    $issues = [Collections.Generic.List[string]]::new()
    $principal = Get-WindowsFinalizationTaskProperty $Task 'Principal'
    $settings = Get-WindowsFinalizationTaskProperty $Task 'Settings'
    $principalSID = $null
    try { $principalSID = Resolve-WindowsFinalizationTaskSID -UserId (Get-WindowsFinalizationTaskProperty $principal 'UserId') }
    catch { $issues.Add('Principal.UserId cannot be resolved to a SID') }
    if ([string]::IsNullOrWhiteSpace($principalSID) -and -not $issues.Count) { $issues.Add('Principal.UserId did not resolve to a SID') }
    if ($null -ne $principalSID -and $principalSID -cne $ExpectedSID) { $issues.Add('Principal.UserId resolves to a different SID') }
    $logon = Get-WindowsFinalizationTaskProperty $principal 'LogonType'
    if ([string]$logon -notin @('S4U', '2')) { $issues.Add('Principal.LogonType expected S4U/2; actual ' + (Format-WindowsFinalizationTaskValue $logon)) }
    $level = Get-WindowsFinalizationTaskProperty $principal 'RunLevel'
    if ([string]$level -notin @('Highest', 'HighestAvailable', '1')) { $issues.Add('Principal.RunLevel expected highest/1; actual ' + (Format-WindowsFinalizationTaskValue $level)) }
    $actions = @((Get-WindowsFinalizationTaskProperty $Task 'Actions') | Where-Object { $null -ne $_ })
    if ($actions.Count -ne 1) { $issues.Add("Actions.Count expected 1; actual $($actions.Count)") }
    else {
        if ((Get-WindowsFinalizationTaskProperty $actions[0] 'Execute') -ine "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe") { $issues.Add('Actions.Execute differs from the pinned PowerShell path') }
        $arguments = "-NoLogo -NoProfile -NonInteractive -File `"$SourcePath`" -AttemptId $Attempt -ExpectedScriptSHA256 $SourceSHA256"
        if ((Get-WindowsFinalizationTaskProperty $actions[0] 'Arguments') -cne $arguments) { $issues.Add('Actions.Arguments differs from the exact attempt/source command') }
    }
    $triggers = @((Get-WindowsFinalizationTaskProperty $Task 'Triggers') | Where-Object { $null -ne $_ })
    if ($triggers.Count) { $issues.Add("Triggers.Count expected 0; actual $($triggers.Count)") }
    $limit = Get-WindowsFinalizationTaskProperty $settings 'ExecutionTimeLimit'
    $duration = $null
    try { $duration = [Xml.XmlConvert]::ToTimeSpan([string]$limit) } catch { }
    if ($null -eq $duration -or $duration -ne [TimeSpan]::FromMinutes(18)) { $issues.Add('Settings.ExecutionTimeLimit expected exactly 18 minutes; actual ' + (Format-WindowsFinalizationTaskValue $limit)) }
    $instances = Get-WindowsFinalizationTaskProperty $settings 'MultipleInstances'
    if ([string]$instances -notin @('IgnoreNew', '2')) { $issues.Add('Settings.MultipleInstances expected IgnoreNew/2; actual ' + (Format-WindowsFinalizationTaskValue $instances)) }
    $restart = Get-WindowsFinalizationTaskProperty $settings 'RestartCount'
    if ($null -eq $restart -or [string]$restart -cne '0') { $issues.Add('Settings.RestartCount expected 0; actual ' + (Format-WindowsFinalizationTaskValue $restart)) }
    $terminate = Get-WindowsFinalizationTaskProperty $settings 'AllowHardTerminate'
    if ($terminate -isnot [bool] -or -not $terminate) { $issues.Add('Settings.AllowHardTerminate expected Boolean true; actual ' + (Format-WindowsFinalizationTaskValue $terminate)) }
    if ($issues.Count) { throw ('Finalization task mismatch: ' + ($issues -join '; ')) }
    return $principalSID
}

function Register-WindowsImageFinalizationTask {
    param([string] $Attempt, [string] $SourceSHA256, [string] $SourcePath, [switch] $AllowTemporaryBatchLogonAssignment)
    if (-not $AllowTemporaryBatchLogonAssignment) { throw 'Approve the possible temporary own-account batch-logon assignment before registering this task' }
    if ($Attempt -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' -or $SourceSHA256 -cnotmatch '^[a-f0-9]{64}$' -or $SourcePath -ine 'C:\Windows\Temp\Complete-WindowsRunnerImage.ps1') { throw 'Invalid finalization task identity' }
    if ((Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $SourceSHA256) { throw 'Finalizer source changed after staging' }
    $identity = Get-WindowsFinalizationIdentity
    $account = Get-WindowsImageBuildAccount
    Assert-WindowsFinalizationAdministrator -ExpectedSID $account.sid
    $batchPolicy = Get-WindowsBatchLogonPolicy
    Assert-WindowsBatchLogonPolicy -Policy $batchPolicy -Identity $identity
    Save-WindowsBatchLogonBaseline -Root "$env:ProgramData\GitHubRunner" -Attempt $Attempt -SourceSHA256 $SourceSHA256 -SID $account.sid -Policy $batchPolicy
    $taskName = 'GitHubRunnerImageFinalize-' + $Attempt.Replace('-', '')
    $executable = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = "-NoLogo -NoProfile -NonInteractive -File `"$SourcePath`" -AttemptId $Attempt -ExpectedScriptSHA256 $SourceSHA256"
    $existing = @(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskName -eq $taskName)
    if (-not $existing.Count) {
        # Same-user S4U stores no password. Existing administrators have batch
        # logon rights by default; an explicitly approved redundant assignment
        # is removed after the task. Never grant missing effective access.
        $principal = New-ScheduledTaskPrincipal -UserId $account.sid -LogonType S4U -RunLevel Highest
        $action = New-ScheduledTaskAction -Execute $executable -Argument $arguments
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(18)) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
    }
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $null = Assert-WindowsImageFinalizationTask -Task $task -ExpectedSID $account.sid -SourcePath $SourcePath -Attempt $Attempt -SourceSHA256 $SourceSHA256
    Assert-WindowsBatchLogonDelta -Baseline (Read-WindowsBatchLogonBaseline -Root "$env:ProgramData\GitHubRunner" -Attempt $Attempt -SourceSHA256 $SourceSHA256) -Current (Get-WindowsBatchLogonPolicy)
    Write-Output "Staged independent administrator finalization task for attempt $Attempt; not started."
}

function Get-WindowsFinalizationIdentity { return [Security.Principal.WindowsIdentity]::GetCurrent() }
function Test-WindowsFinalizationElevation { return ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Assert-WindowsFinalizationAdministrator {
    param([string] $ExpectedSID)
    $identity = Get-WindowsFinalizationIdentity
    if ($identity.IsSystem -or $identity.User.Value -cne $ExpectedSID -or -not (Test-WindowsFinalizationElevation)) { throw 'Sysprep requires the existing elevated build administrator, never SYSTEM' }
}

function Complete-WindowsImageFinalizationAttempt {
    param([string] $Root, $Record)
    $started = Get-Content -LiteralPath (Join-Path $Root 'image-finalization.started.json') -Raw | ConvertFrom-Json
    if ($started.attemptId -cne $Record.attemptId -or $started.scriptSHA256 -cne $Record.scriptSHA256 -or $Record.status -cne 'Succeeded') { throw 'Finalization completion does not match its one-shot attempt' }
    $pending = Join-Path $Root 'image-finalization.pending.json'
    $stream = [IO.File]::Open($pending, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Depth 5 -Compress))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } finally { $stream.Dispose() }
    # Same-volume atomic publication; never replace an existing completion.
    [IO.File]::Move($pending, (Join-Path $Root 'image-finalization.complete.json'))
}


function Initialize-WindowsBatchPolicyNative {
    if ('RunnerImage.BatchPolicy' -as [type]) { return }
    # Native declarations only. No policy handle is opened when tests compile
    # this type; production exposes enumeration and one-right removal, no grant.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
namespace RunnerImage {
    public static class BatchPolicy {
        [StructLayout(LayoutKind.Sequential)] struct Attributes {
            public uint Length; public IntPtr RootDirectory; public IntPtr ObjectName;
            public uint Flags; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
        }
        [StructLayout(LayoutKind.Sequential)] struct UnicodeString {
            public ushort Length; public ushort MaximumLength; public IntPtr Buffer;
        }
        [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref Attributes attributes, uint access, out IntPtr handle);
        [DllImport("advapi32.dll")] static extern uint LsaEnumerateAccountsWithUserRight(IntPtr handle, ref UnicodeString right, out IntPtr buffer, out uint count);
        [DllImport("advapi32.dll")] static extern uint LsaRemoveAccountRights(IntPtr handle, IntPtr sid, [MarshalAs(UnmanagedType.U1)] bool allRights, [In] UnicodeString[] rights, uint count);
        [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
        [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr buffer);
        [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
        static void Check(uint status) { if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status)); }
        static IntPtr Open(uint access) {
            var attributes = new Attributes(); attributes.Length = (uint)Marshal.SizeOf(typeof(Attributes));
            IntPtr handle; Check(LsaOpenPolicy(IntPtr.Zero, ref attributes, access, out handle)); return handle;
        }
        static UnicodeString Right(string name) {
            if (name != "SeBatchLogonRight" && name != "SeDenyBatchLogonRight") throw new ArgumentException("Unexpected policy right");
            return new UnicodeString { Length = (ushort)(name.Length * 2), MaximumLength = (ushort)((name.Length + 1) * 2), Buffer = Marshal.StringToHGlobalUni(name) };
        }
        public static string[] Read(string name) {
            IntPtr handle = IntPtr.Zero, buffer = IntPtr.Zero; var right = Right(name);
            try {
                handle = Open(0x00000801);
                uint count; uint status = LsaEnumerateAccountsWithUserRight(handle, ref right, out buffer, out count);
                if (status == 0x8000001A) return new string[0]; // STATUS_NO_MORE_ENTRIES
                Check(status); var result = new string[count];
                for (int i = 0; i < count; i++) result[i] = new SecurityIdentifier(Marshal.ReadIntPtr(buffer, i * IntPtr.Size)).Value;
                return result;
            } finally { if (buffer != IntPtr.Zero) LsaFreeMemory(buffer); Marshal.FreeHGlobal(right.Buffer); if (handle != IntPtr.Zero) LsaClose(handle); }
        }
        public static void RemoveTemporaryBatchGrant(string value) {
            var sid = new SecurityIdentifier(value); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
            IntPtr handle = IntPtr.Zero, nativeSid = Marshal.AllocHGlobal(bytes.Length); var right = Right("SeBatchLogonRight");
            try {
                handle = Open(0x00000800);
                Marshal.Copy(bytes, 0, nativeSid, bytes.Length);
                Check(LsaRemoveAccountRights(handle, nativeSid, false, new[] { right }, 1));
            } finally { Marshal.FreeHGlobal(nativeSid); Marshal.FreeHGlobal(right.Buffer); if (handle != IntPtr.Zero) LsaClose(handle); }
        }
    }
}
'@
}

function Get-WindowsBatchLogonPolicy {
    Initialize-WindowsBatchPolicyNative
    return @{ SeBatchLogonRight = @([RunnerImage.BatchPolicy]::Read('SeBatchLogonRight')); SeDenyBatchLogonRight = @([RunnerImage.BatchPolicy]::Read('SeDenyBatchLogonRight')) }
}

function Assert-WindowsBatchLogonPolicy {
    param($Policy, $Identity)
    foreach ($entry in @($Policy.SeBatchLogonRight) + @($Policy.SeDenyBatchLogonRight)) {
        if ($entry -cnotmatch '^S-1-\d+(-\d+)+$') { throw 'Cannot resolve a batch-logon policy entry to a verified SID' }
    }
    $identities = @($Identity.User.Value) + @($Identity.Groups | ForEach-Object { $_.Value })
    if (@($Policy.SeDenyBatchLogonRight | Where-Object { $_ -in $identities }).Count) { throw 'Existing policy denies batch logon for the build administrator' }
    # The caller has already proved its elevated Administrators token. Fail on
    # unfamiliar name-based assignments instead of modifying local policy.
    if (-not @($Policy.SeBatchLogonRight | Where-Object { $_ -in @($Identity.User.Value, 'S-1-5-32-544') }).Count) { throw 'Existing build administrator lacks batch-logon permission' }
}

function Read-WindowsBatchLogonBaseline {
    param([string] $Root, [string] $Attempt, [string] $SourceSHA256)
    $baseline = Get-Content -LiteralPath (Join-Path $Root 'image-finalization.batch-policy.json') -Raw | ConvertFrom-Json
    if ($baseline.attemptId -cne $Attempt -or $baseline.scriptSHA256 -cne $SourceSHA256 -or $baseline.sid -cnotmatch '^S-1-5-21-\d+-\d+-\d+-(500|[1-9]\d{3,})$') { throw 'Batch-logon baseline belongs to another attempt' }
    return $baseline
}

function Assert-WindowsBatchLogonDelta {
    param($Baseline, $Current)
    $beforeAllow = @($Baseline.allow | Sort-Object -Unique)
    $afterAllow = @($Current.SeBatchLogonRight | Sort-Object -Unique)
    if (@($beforeAllow | Where-Object { $_ -notin $afterAllow }).Count -or @($afterAllow | Where-Object { $_ -notin $beforeAllow -and $_ -cne $Baseline.sid }).Count -or
        ((@($Baseline.deny | Sort-Object -Unique) -join ',') -cne (@($Current.SeDenyBatchLogonRight | Sort-Object -Unique) -join ','))) { throw 'Unexpected batch-logon policy change; refusing broad restoration' }
}

function Save-WindowsBatchLogonBaseline {
    param([string] $Root, [string] $Attempt, [string] $SourceSHA256, [string] $SID, $Policy)
    $path = Join-Path $Root 'image-finalization.batch-policy.json'
    if (Test-Path -LiteralPath $path) {
        $baseline = Read-WindowsBatchLogonBaseline -Root $Root -Attempt $Attempt -SourceSHA256 $SourceSHA256
        if ($baseline.sid -cne $SID) { throw 'Batch-logon baseline account changed' }
        Assert-WindowsBatchLogonDelta -Baseline $baseline -Current $Policy
        return
    }
    $baseline = @{ attemptId = $Attempt; scriptSHA256 = $SourceSHA256; sid = $SID; allow = @($Policy.SeBatchLogonRight); deny = @($Policy.SeDenyBatchLogonRight) }
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($baseline | ConvertTo-Json -Depth 5 -Compress))
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
}

function Remove-WindowsTemporaryBatchLogonAssignment {
    param([string] $SID)
    if ($SID -cnotmatch '^S-1-5-21-\d+-\d+-\d+-(500|[1-9]\d{3,})$') { throw 'Invalid temporary build account SID' }
    Initialize-WindowsBatchPolicyNative
    [RunnerImage.BatchPolicy]::RemoveTemporaryBatchGrant($SID)
}

function Restore-WindowsBatchLogonBaseline {
    param([string] $Root, [string] $Attempt, [string] $SourceSHA256)
    $baseline = Read-WindowsBatchLogonBaseline -Root $Root -Attempt $Attempt -SourceSHA256 $SourceSHA256
    $current = Get-WindowsBatchLogonPolicy
    Assert-WindowsBatchLogonDelta -Baseline $baseline -Current $current
    $expected = @($baseline.allow | Sort-Object -Unique) -join ','
    if ((@($current.SeBatchLogonRight | Sort-Object -Unique) -join ',') -cne $expected) { Remove-WindowsTemporaryBatchLogonAssignment -SID $baseline.sid }
    $after = Get-WindowsBatchLogonPolicy
    if ((@($after.SeBatchLogonRight | Sort-Object -Unique) -join ',') -cne $expected -or
        ((@($after.SeDenyBatchLogonRight | Sort-Object -Unique) -join ',') -cne (@($baseline.deny | Sort-Object -Unique) -join ','))) { throw 'Batch-logon policy did not return to its exact baseline' }
}

function Wait-WindowsImageFinalizationTask {
    param([string] $Root, [string] $Attempt, [string] $SourceSHA256, [string] $SourcePath)
    if (-not (Get-WindowsFinalizationIdentity).IsSystem) { throw 'Managed observer must use the Azure agent identity' }
    $taskName = 'GitHubRunnerImageFinalize-' + $Attempt.Replace('-', '')
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $baseline = Read-WindowsBatchLogonBaseline -Root $Root -Attempt $Attempt -SourceSHA256 $SourceSHA256
    $principalSID = Assert-WindowsImageFinalizationTask -Task $task -ExpectedSID $baseline.sid -SourcePath $SourcePath -Attempt $Attempt -SourceSHA256 $SourceSHA256
    $dispatchPath = Join-Path $Root 'image-finalization.dispatched.json'
    $completedPath = Join-Path $Root 'image-finalization.complete.json'
    $observedPath = Join-Path $Root 'image-finalization.observed.json'
    $ownsTask = $true
    $diagnosticContext = @{ root = $Root; attempt = $Attempt; sha = $SourceSHA256 }
    $observerOperation = 'observer-task'
    try {
        if (-not (Test-Path -LiteralPath $dispatchPath)) {
            $account = Get-WindowsImageBuildAccount
            if ($account.sid -cne $principalSID) { throw 'Finalization task does not belong to the build administrator' }
            $before = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
            $record = @{ attemptId = $Attempt; scriptSHA256 = $SourceSHA256; priorRunTime = $before.LastRunTime.ToUniversalTime().ToString('o') }
            $stream = [IO.File]::Open($dispatchPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Compress))
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
            # This starts the previously staged own-user S4U task. No credential
            # crosses the agent boundary, and no second launch is attempted.
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        }
        $dispatch = Get-Content -LiteralPath $dispatchPath -Raw | ConvertFrom-Json
        if ($dispatch.attemptId -cne $Attempt -or $dispatch.scriptSHA256 -cne $SourceSHA256) { throw 'Dispatch marker belongs to another attempt' }
        $deadline = (Get-WindowsImageTaskTime).AddMinutes(19)
        $lastPhase = ''
        while ((Get-WindowsImageTaskTime) -lt $deadline) {
            $phasePath = Join-Path $Root 'image-finalization.phase.txt'
            if (Test-Path -LiteralPath $phasePath) {
                $phase = (Get-Content -LiteralPath $phasePath -Raw).Trim()
                if ($phase -cmatch '^Finalization phase: [a-z-]+$' -and $phase -cne $lastPhase) { Write-Host $phase; $lastPhase = $phase }
            }
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
            $newRun = $info.LastRunTime.ToUniversalTime() -gt [DateTime]::Parse($dispatch.priorRunTime).ToUniversalTime()
            if ($newRun -and $task.State -notin @('Running', 'Queued')) {
                if ($info.LastTaskResult -ne 0) { throw "Administrator finalization task failed with code $($info.LastTaskResult)" }
                if (-not (Test-Path -LiteralPath $completedPath)) { throw 'Task exited without finalization completion' }
                break
            }
            Wait-WindowsImageTaskPoll
        }
        if (-not $newRun -or $task.State -in @('Running', 'Queued')) { throw 'Administrator finalization task did not finish before its deadline' }
        $observerOperation = 'observer-state'
        $proof = Get-Content -LiteralPath $completedPath -Raw | ConvertFrom-Json
        if ($proof.attemptId -cne $Attempt -or $proof.scriptSHA256 -cne $SourceSHA256 -or $proof.status -cne 'Succeeded' -or $proof.accountCleanup.sid -cne $principalSID) { throw 'Task completion does not match the current administrator attempt' }
        $started = Get-Content -LiteralPath (Join-Path $Root 'image-finalization.started.json') -Raw | ConvertFrom-Json
        if ($started.attemptId -cne $Attempt -or $started.scriptSHA256 -cne $SourceSHA256 -or $started.executionSID -cne $principalSID) { throw 'Task did not confirm execution as the expected administrator' }
        # Independent agent-side readbacks, after the administrator process has
        # exited. Never accept the worker's boolean assertions on their own.
        $imageState = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction Stop).ImageState
        Assert-WindowsImageAccountCleanup -Cleanup $proof.accountCleanup -GeneralizationState $imageState
        if ((Test-WindowsBuildCngKey -Identity $proof.keyIdentity) -or (Get-WindowsBuildKeyFile -Identity $proof.keyIdentity)) { throw 'Observer cannot verify build private-key absence' }
        if (@(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object { $_.Thumbprint -ieq $proof.keyIdentity.thumbprint -or $_.FriendlyName -eq 'GitHubRunnerPackerWinRM' }).Count) { throw 'Observer found the build certificate' }
        Assert-WindowsFinalizationWinRMService
        if (@(Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop).Count) { throw 'Observer found a WinRM listener' }
        if (@(Get-NetFirewallRule -ErrorAction Stop | Where-Object Name -eq 'WINRM-Packer-Build').Count) { throw 'Observer found the build firewall rule' }
        if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop).LocalAccountTokenFilterPolicy -ne 0) { throw 'Observer found the build token policy' }
        $runtime = Get-ScheduledTask -TaskName 'GitHubEphemeralRunner' -ErrorAction Stop
        Assert-WindowsRuntimeTask -Task $runtime
        $observerOperation = 'observer-cleanup'
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        if (@(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskName -eq $taskName).Count) { throw 'Finalization task remains after removal' }
        $ownsTask = $false
        Restore-WindowsBatchLogonBaseline -Root $Root -Attempt $Attempt -SourceSHA256 $SourceSHA256
        Remove-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
        if (@(Get-ChildItem -LiteralPath (Split-Path $SourcePath -Parent) -Force -ErrorAction Stop | Where-Object Name -eq (Split-Path $SourcePath -Leaf)).Count) { throw 'Staged finalizer remains after removal' }
        $proof.PSObject.Properties.Remove('accountCleanup')
        $proof.PSObject.Properties.Remove('keyIdentity')
        $proof | Add-Member -NotePropertyName finalizationTaskAbsent -NotePropertyValue $true
        $proof | Add-Member -NotePropertyName batchLogonPolicyRestored -NotePropertyValue $true
        $pending = $observedPath + '.pending'
        [IO.File]::WriteAllText($pending, ($proof | ConvertTo-Json -Depth 5 -Compress), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($pending, $observedPath)
        return $proof
    } catch {
        Write-WindowsFinalizationFailureEvidence -Context $diagnosticContext -Operation $observerOperation -Failure $_
        throw
    } finally {
        if ($ownsTask) {
            # Agent cancellation may interrupt this block. The task's own 18m
            # limit and Packer's VM/resource-group teardown remain mandatory.
            Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $remaining = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            if ($remaining.State -in @('Running', 'Queued')) { throw 'Finalization task termination was not confirmed' }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            if (@(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskName -eq $taskName).Count) { throw 'Failed finalization task remains after removal' }
        }
    }
}

function Get-WindowsImageTaskTime { return [DateTime]::UtcNow }
function Wait-WindowsImageTaskPoll { Start-Sleep -Seconds 5 }
function Write-WindowsImageFinalizationPhase {
    param([string] $Root, [string] $Phase)
    $line = 'Finalization phase: ' + $Phase
    [IO.File]::WriteAllText((Join-Path $Root 'image-finalization.phase.txt'), $line)
    Write-Output $line
}


function Get-WindowsFinalizationFailureOperations {
    return @('administrator-check', 'attempt-create', 'image-preflight', 'runtime-task-create', 'maintenance-policy', 'identity-cleanup', 'account-preflight', 'certificate-preflight', 'guest-agent-check', 'winrm-service-check', 'listeners-read', 'listeners-remove', 'firewall-read', 'firewall-remove', 'token-policy-restore', 'listeners-verify', 'firewall-verify', 'token-policy-verify', 'sysprep', 'certificate-cleanup', 'account-cleanup', 'account-verify', 'manifest-publish', 'runtime-task-read', 'runtime-task-verify', 'generalization-read', 'completion-publish', 'observer-task', 'observer-state', 'observer-cleanup')
}

function New-WindowsFinalizationFailure {
    param($Context, [string] $Operation, $Failure)
    if ($Operation -cnotin (Get-WindowsFinalizationFailureOperations)) { throw 'Unknown finalization operation' }
    $errors = @()
    $exception = $Failure.Exception
    while ($null -ne $exception -and $errors.Count -lt 3) {
        $type = $exception.GetType().FullName
        if ($type -cnotin @('System.Exception', 'System.InvalidOperationException', 'System.UnauthorizedAccessException', 'System.ComponentModel.Win32Exception', 'System.Runtime.InteropServices.COMException', 'System.Security.Cryptography.CryptographicException', 'System.Management.Automation.RuntimeException', 'System.Management.Automation.CmdletInvocationException', 'System.Management.Automation.MethodInvocationException', 'System.Management.Automation.ItemNotFoundException', 'Microsoft.Management.Infrastructure.CimException')) { $type = 'Other' }
        $errors += @{ type = $type; hresult = [int]$exception.HResult }
        $exception = $exception.InnerException
    }
    return [pscustomobject]@{
        schemaVersion = 1; status = 'Failed'; attemptId = $Context.attempt; scriptSHA256 = $Context.sha
        operation = $Operation; sourceLine = [int]$Failure.InvocationInfo.ScriptLineNumber
        category = [int]$Failure.CategoryInfo.Category; errors = $errors
    }
}

function Save-WindowsFinalizationFailure {
    param($Context, [string] $Operation, $Failure)
    $path = Join-Path $Context.root 'image-finalization.failure.json'
    if (Test-Path -LiteralPath $path) { return }
    $record = New-WindowsFinalizationFailure -Context $Context -Operation $Operation -Failure $Failure
    $pending = $path + '.pending'
    $stream = [IO.File]::Open($pending, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 5 -Compress))
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    [IO.File]::Move($pending, $path)
}

function Read-WindowsFinalizationFailure {
    param($Context)
    $path = Join-Path $Context.root 'image-finalization.failure.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    if ($text.Length -gt 2048) { throw 'Oversized finalization failure record' }
    $record = $text | ConvertFrom-Json
    if ($record.schemaVersion -ne 1 -or $record.status -cne 'Failed' -or $record.attemptId -cne $Context.attempt -or $record.scriptSHA256 -cne $Context.sha -or $record.operation -cnotin (Get-WindowsFinalizationFailureOperations) -or ($record.sourceLine -isnot [int] -and $record.sourceLine -isnot [long]) -or $record.sourceLine -lt 0 -or $record.sourceLine -gt 100000 -or ($record.category -isnot [int] -and $record.category -isnot [long]) -or $record.category -lt 0 -or $record.category -gt 31 -or @($record.errors).Count -notin @(1, 2, 3)) { throw 'Mismatched finalization failure record' }
    $errors = @()
    foreach ($entry in $record.errors) {
        if (($entry.hresult -isnot [int] -and $entry.hresult -isnot [long]) -or $entry.hresult -lt [int]::MinValue -or $entry.hresult -gt [int]::MaxValue) { throw 'Invalid failure HRESULT' }
        $type = [string]$entry.type
        if ($type -cnotin @('System.Exception', 'System.InvalidOperationException', 'System.UnauthorizedAccessException', 'System.ComponentModel.Win32Exception', 'System.Runtime.InteropServices.COMException', 'System.Security.Cryptography.CryptographicException', 'System.Management.Automation.RuntimeException', 'System.Management.Automation.CmdletInvocationException', 'System.Management.Automation.MethodInvocationException', 'System.Management.Automation.ItemNotFoundException', 'Microsoft.Management.Infrastructure.CimException', 'Other')) { throw 'Unknown failure exception type' }
        $errors += @{ type = $type; hresult = $entry.hresult }
    }
    # Project only approved metadata, never any extra fields found in the file.
    return [pscustomobject]@{ schemaVersion = 1; status = 'Failed'; attemptId = $record.attemptId; scriptSHA256 = $record.scriptSHA256; operation = $record.operation; sourceLine = $record.sourceLine; category = $record.category; errors = $errors }
}


function Write-WindowsFinalizationFailureEvidence {
    param($Context, [string] $Operation, $Failure)
    $record = $null
    try { $record = Read-WindowsFinalizationFailure -Context $Context }
    catch { Write-Warning 'Worker failure metadata is unavailable or invalid.' }
    try {
        if ($null -eq $record) { $record = New-WindowsFinalizationFailure -Context $Context -Operation $Operation -Failure $Failure }
        Write-Host ('GHA_IMAGE_FINALIZATION_FAILURE ' + ($record | ConvertTo-Json -Depth 5 -Compress))
    } catch { Write-Warning 'Finalization failure evidence could not be emitted.' }
}

function Invoke-WindowsFinalizationOperation {
    param($Context, [string] $Operation, [scriptblock] $Action)
    try {
        Write-WindowsImageFinalizationPhase -Root $Context.root -Phase $Operation | Out-Null
        & $Action
    } catch {
        # Diagnostics must never replace the original terminating failure.
        try { Save-WindowsFinalizationFailure -Context $Context -Operation $Operation -Failure $_ }
        catch { Write-Warning 'Finalization failure metadata could not be saved.' }
        throw
    }
}

function Assert-WindowsRuntimeTask {
    param($Task)
    $principal = Get-WindowsFinalizationTaskProperty $Task 'Principal'
    try { $sid = Resolve-WindowsFinalizationTaskSID -UserId (Get-WindowsFinalizationTaskProperty $principal 'UserId') }
    catch { throw 'Runtime task principal cannot be resolved to a SID' }
    $state = [string](Get-WindowsFinalizationTaskProperty $Task 'State')
    if ($sid -cne 'S-1-5-18' -or $state -notin @('Ready', 'Running', 'Queued', '3', '4', '2')) { throw 'Runtime task must use SYSTEM and be enabled' }
}

function Assert-WindowsFinalizationWinRMService {
    if ((Get-Service -Name WinRM -ErrorAction Stop).Status -ne 'Running') { throw 'WinRM service stopped before its explicit configuration readback' }
}

function Remove-WindowsImageBuildRemoting {
    param($Context)
    Invoke-WindowsFinalizationOperation $Context 'winrm-service-check' { Assert-WindowsFinalizationWinRMService }
    $listeners = @(Invoke-WindowsFinalizationOperation $Context 'listeners-read' { Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop })
    Invoke-WindowsFinalizationOperation $Context 'listeners-remove' { $listeners | Remove-Item -Recurse -Force -ErrorAction Stop }
    $rules = @(Invoke-WindowsFinalizationOperation $Context 'firewall-read' { Get-NetFirewallRule -ErrorAction Stop | Where-Object Name -eq 'WINRM-Packer-Build' })
    Invoke-WindowsFinalizationOperation $Context 'firewall-remove' { $rules | Remove-NetFirewallRule -ErrorAction Stop }
    Invoke-WindowsFinalizationOperation $Context 'token-policy-restore' { New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 0 -Force | Out-Null }
    Invoke-WindowsFinalizationOperation $Context 'listeners-verify' { Assert-WindowsFinalizationWinRMService; if (@(Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop).Count) { throw 'Build WinRM listener remains' } }
    Invoke-WindowsFinalizationOperation $Context 'firewall-verify' { if (@(Get-NetFirewallRule -ErrorAction Stop | Where-Object Name -eq 'WINRM-Packer-Build').Count) { throw 'Build firewall rule remains' } }
    Invoke-WindowsFinalizationOperation $Context 'token-policy-verify' { if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop).LocalAccountTokenFilterPolicy -ne 0) { throw 'Build token policy was not restored' } }
}

function Invoke-WindowsImageSysprep {
    & "$env:SystemRoot\System32\Sysprep\Sysprep.exe" /oobe /generalize /quiet /quit /mode:vm
    if ($LASTEXITCODE -ne 0) { throw [ComponentModel.Win32Exception]::new($LASTEXITCODE) }
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    while ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Sysprep timed out' }
        Start-Sleep -Seconds 10
    }
}

function Complete-WindowsImageBuildIdentity {
    param($Context)
    $buildAccount = Invoke-WindowsFinalizationOperation $Context 'account-preflight' { Get-WindowsImageBuildAccount }
    Invoke-WindowsFinalizationOperation $Context 'winrm-service-check' { Assert-WindowsFinalizationWinRMService }
    $buildCertificate = Invoke-WindowsFinalizationOperation $Context 'certificate-preflight' { Get-WindowsImageBuildCertificate }
    Invoke-WindowsFinalizationOperation $Context 'guest-agent-check' {
        foreach ($service in Get-Service -Name RdAgent, WindowsAzureGuestAgent -ErrorAction Stop) {
            if ($service.Status -ne 'Running') { throw 'Azure guest agent is not ready' }
        }
    }
    # Local WSMan uses the caller identity. Complete its configuration work while
    # that identity and TLS key are intact, before Server Sysprep clears credentials.
    Remove-WindowsImageBuildRemoting -Context $Context
    Invoke-WindowsFinalizationOperation $Context 'sysprep' { Invoke-WindowsImageSysprep }
    $certificateCleanup = Invoke-WindowsFinalizationOperation $Context 'certificate-cleanup' { Remove-WindowsImageBuildCertificate -Identity $buildCertificate }
    $accountCleanup = Invoke-WindowsFinalizationOperation $Context 'account-cleanup' { Remove-WindowsImageBuildAccount -Expected $buildAccount }
    Invoke-WindowsFinalizationOperation $Context 'account-verify' { Assert-WindowsImageAccountCleanup -Cleanup $accountCleanup -GeneralizationState (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState }
    return @{ account = $accountCleanup; certificate = $certificateCleanup; keyIdentity = @{ thumbprint = $buildCertificate.thumbprint; provider = $buildCertificate.provider; machineKey = $buildCertificate.machineKey; keyName = $buildCertificate.keyName; uniqueName = $buildCertificate.uniqueName } }
}

# Tests load only functions, without preparing the host.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($RegisterTask) {
    Register-WindowsImageFinalizationTask -Attempt $AttemptId -SourceSHA256 $ExpectedScriptSHA256 -SourcePath $PSCommandPath -AllowTemporaryBatchLogonAssignment:$AllowTemporaryBatchLogonAssignment
    return
}
$stateRoot = "$env:ProgramData\GitHubRunner"
$context = @{ root = $stateRoot; attempt = $AttemptId; sha = $ExpectedScriptSHA256 }
$operation = 'administrator-check'
try {
Assert-WindowsFinalizationAdministrator -ExpectedSID (Get-WindowsImageBuildAccount).sid

$operation = 'attempt-create'
Start-WindowsImageFinalizationAttempt -Root $stateRoot -Attempt $AttemptId -SourceSHA256 $ExpectedScriptSHA256 -SourcePath $PSCommandPath -ExecutionSID (Get-WindowsFinalizationIdentity).User.Value
$operation = 'image-preflight'
Write-WindowsImageFinalizationPhase -Root $stateRoot -Phase $operation
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

$operation = 'runtime-task-create'
# Jobs use SYSTEM in a disposable VM. No interactive desktop session is provided.
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoLogo -NoProfile -NonInteractive -File `"$stateRoot\Start-WindowsRunner.ps1`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName 'GitHubEphemeralRunner' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
$operation = 'maintenance-policy'
# Images are refreshed for security patches; update scans must not interrupt jobs.
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -PropertyType DWord -Value 1 -Force | Out-Null
$operation = 'identity-cleanup'
$cleanup = Complete-WindowsImageBuildIdentity -Context $context
$accountCleanup = $cleanup.account
$certificateCleanup = $cleanup.certificate
$operation = 'manifest-publish'
$manifest | Add-Member -NotePropertyName imageAccountCleanup -NotePropertyValue @{ mode = $accountCleanup.mode; sysprepState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'; serverSysprepCompleted = $true; buildAccountAbsent = $true } -Force
$manifest | Add-Member -NotePropertyName imageCertificateCleanup -NotePropertyValue $certificateCleanup -Force
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stateRoot 'manifest.json')
$operation = 'runtime-task-read'
$runtimeTask = Get-ScheduledTask -TaskName 'GitHubEphemeralRunner' -ErrorAction Stop
$operation = 'runtime-task-verify'
Assert-WindowsRuntimeTask -Task $runtimeTask
$operation = 'generalization-read'
$generalizationState = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction Stop).ImageState
$operation = 'account-verify'
Assert-WindowsImageAccountCleanup -Cleanup $accountCleanup -GeneralizationState $generalizationState
$operation = 'completion-publish'
Complete-WindowsImageFinalizationAttempt -Root $stateRoot -Record @{
    schemaVersion = 1; attemptId = $AttemptId; scriptSHA256 = $ExpectedScriptSHA256; status = 'Succeeded'
    sysprepState = $generalizationState; buildAccountRetired = $true
    privateKeyAbsent = $certificateCleanup.privateKeyAbsent; certificateAbsent = $certificateCleanup.certificateAbsent
    winrmListenersAbsent = $true; buildFirewallRuleAbsent = $true; tokenPolicyRestored = $true; runtimeTaskPresent = $true
    accountCleanup = $accountCleanup; keyIdentity = $cleanup.keyIdentity
}
} catch {
    try { Save-WindowsFinalizationFailure -Context $context -Operation $operation -Failure $_ }
    catch { Write-Warning 'Finalization failure metadata could not be saved.' }
    throw
}
