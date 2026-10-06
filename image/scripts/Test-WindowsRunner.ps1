[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-WindowsRunner.ps1')

$buildScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Initialize-WindowsRunnerImage.ps1') -Raw
$buildEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($buildScript))
# Reserve 1 KiB for the fixed command wrapper and the longest IPv4 /32.
if ($buildEncoded.Length + 1024 -ge 8191) { throw 'Build bootstrap exceeds the Windows command-line limit' }
$packerTemplate = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../windows-runner.pkr.hcl') -Raw
if ($packerTemplate -notmatch 'skip_create_build_key_vault\s*=\s*true' -or $packerTemplate -notmatch 'winrm_use_ntlm\s*=\s*true' -or $packerTemplate -match '(?m)^\s*(winrm_password|user_data|user_data_file|build_key_vault_name)\s*=') { throw 'Build template reintroduced a vault or credential-bearing bootstrap input' }

# Inspect the real provider's command metadata without creating or deleting a
# certificate. Pipeline input cannot select DeleteKey during parameter binding.
$certificateDeleteKey = (Get-Command Microsoft.PowerShell.Management\Remove-Item -ArgumentList 'Cert:\LocalMachine\My').Parameters.ContainsKey('DeleteKey')
$filesystemDeleteKey = (Get-Command Microsoft.PowerShell.Management\Remove-Item -ArgumentList $PSScriptRoot).Parameters.ContainsKey('DeleteKey')
if (-not $certificateDeleteKey -or $filesystemDeleteKey) { throw 'Unexpected Certificate provider dynamic-parameter binding' }

# Keep remoting tests in their own scope: these mocks never change host services,
# certificates, firewall rules, or registry settings on the hosted CI runner.
function Test-WindowsBuildRemoting {
    . (Join-Path $PSScriptRoot 'Initialize-WindowsRunnerImage.ps1')
    $calls = [Collections.Generic.List[string]]::new()
    $settings = @{}
    $certificateState = @{ hasOldCertificate = $false }
    function Set-Service { param($Name, $StartupType) $calls.Add('service') }
    function Start-Service { param($Name) $calls.Add('start') }
    function Get-ChildItem {
        param($Path)
        if ($Path -like 'WSMan:*') { return 'old-listener' }
        if ($Path -like 'Cert:*') {
            if ($certificateState.hasOldCertificate) { return [pscustomobject]@{ FriendlyName = 'GitHubRunnerPackerWinRM'; Thumbprint = 'old-build-key' } }
            return
        }
        throw "Unexpected remoting path: $Path"
    }
    function Remove-Item {
        param([Parameter(Position=0)][string] $Path, [Parameter(ValueFromPipeline)] $InputObject, [switch] $Recurse, [switch] $Force, [switch] $DeleteKey)
        process {
            if ($DeleteKey) {
                if ($Path -cne 'Cert:\LocalMachine\My\old-build-key') { throw 'DeleteKey requires an explicit Certificate provider path' }
                $calls.Add('delete-old-key')
            } else { $calls.Add('delete-old-listener') }
        }
    }
    function Get-NetFirewallRule { [CmdletBinding()] param($Name) return $Name }
    function Disable-NetFirewallRule { param([Parameter(ValueFromPipeline)] $InputObject) process { $calls.Add("disable:$InputObject") } }
    function Remove-NetFirewallRule { param([Parameter(ValueFromPipeline)] $InputObject) process { $calls.Add("remove:$InputObject") } }
    function Set-Item { param($Path, $Value) $settings[$Path] = $Value }
    function New-ItemProperty {
        param($Path, $Name, $PropertyType, $Value, [switch] $Force)
        if ($Name -ne 'LocalAccountTokenFilterPolicy' -or $Value -ne 1) { throw 'Unexpected build token policy' }
        $calls.Add('temporary-admin-token')
    }
    function New-SelfSignedCertificate {
        param($DnsName, $CertStoreLocation, $FriendlyName, $Provider, $KeyAlgorithm, $KeySpec, $KeyExportPolicy, $NotAfter)
        if ($KeyExportPolicy -ne 'NonExportable' -or $CertStoreLocation -ne 'Cert:\LocalMachine\My' -or $FriendlyName -ne 'GitHubRunnerPackerWinRM' -or $Provider -cne 'Microsoft Software Key Storage Provider' -or $KeyAlgorithm -cne 'RSA' -or $KeySpec -cne 'None') { throw 'Unexpected TLS key provider or export policy' }
        if ($NotAfter -gt (Get-Date).AddHours(4) -or $NotAfter -lt (Get-Date).AddHours(3.9)) { throw 'Unexpected certificate lifetime' }
        $calls.Add('guest-local-key')
        return [pscustomobject]@{ Thumbprint = 'new-build-key' }
    }
    function New-Item {
        param($Path, $Transport, $Address, $CertificateThumbPrint, [switch] $Force)
        if ($Transport -cne 'HTTPS' -or $CertificateThumbPrint -ne 'new-build-key') { throw 'Non-TLS or wrong-key listener' }
        $calls.Add('https-listener')
    }
    function New-NetFirewallRule {
        param($Name, $DisplayName, $Enabled, $Profile, $Action, $Direction, $LocalPort, $Protocol, $RemoteAddress)
        if ($Name -ne 'WINRM-Packer-Build' -or $LocalPort -ne 5986 -or $Protocol -ne 'TCP' -or $RemoteAddress -ne '203.0.113.10/32' -or $Direction -ne 'Inbound' -or $Action -ne 'Allow') { throw 'Build ingress exceeds approved source/port' }
        $calls.Add('scoped-firewall')
    }
    foreach ($bad in @('0.0.0.0/0', '203.0.113.0/24', '999.0.0.1/32', '0.0.0.0/32', '::1/32', "203.0.113.10/32'; Write-Output injected")) {
        $rejected = $false
        try { Initialize-WindowsBuildRemoting -SourceCidr $bad } catch { $rejected = $true }
        if (-not $rejected -or $calls.Count) { throw 'Invalid build source changed remoting state' }
    }
    Initialize-WindowsBuildRemoting -SourceCidr '203.0.113.10/32'
    if ($calls.Contains('delete-old-key') -or -not $calls.Contains('scoped-firewall')) { throw 'Initial setup failed with an empty certificate store' }
    $calls.Clear()
    $certificateState.hasOldCertificate = $true
    1..2 | ForEach-Object { Initialize-WindowsBuildRemoting -SourceCidr '203.0.113.10/32' }
    if ($settings['WSMan:\localhost\Service\AllowUnencrypted'] -ne $false -or $settings['WSMan:\localhost\Service\Auth\Basic'] -ne $false -or $settings['WSMan:\localhost\Service\Auth\Negotiate'] -ne $true) { throw 'Insecure WinRM authentication policy' }
    foreach ($required in @('delete-old-listener', 'delete-old-key', 'disable:WINRM*', 'remove:WINRM-Packer-Build', 'guest-local-key', 'https-listener', 'scoped-firewall')) {
        if (@($calls | Where-Object { $_ -eq $required }).Count -ne 2) { throw "Repeated setup did not replace build remoting safely: $required" }
    }
    Write-Output 'Vault-free build remoting scope, TLS policy, private-key lifetime, and repeated setup tests passed.'
}
Test-WindowsBuildRemoting

function Test-WindowsImageAccountCleanup {
    . (Join-Path $PSScriptRoot 'Complete-WindowsRunnerImage.ps1')
    $state = @{ users = @{}; productType = 3; renameNoOp = $false; disableNoOp = $false; deleteNoOp = $false; calls = [Collections.Generic.List[string]]::new() }
    function Get-CimInstance { param($ClassName) return [pscustomobject]@{ ProductType = $state.productType } }
    function Get-LocalUser {
        [CmdletBinding()] param($SID)
        if ($SID) { return $state.users[$SID.Value] }
        return @($state.users.Values)
    }
    function Rename-LocalUser { [CmdletBinding()] param($SID, $NewName) $state.calls.Add('rename'); if (-not $state.renameNoOp) { $state.users[$SID.Value].Name = $NewName } }
    function Disable-LocalUser { [CmdletBinding()] param($SID) $state.calls.Add('disable'); if (-not $state.disableNoOp) { $state.users[$SID.Value].Enabled = $false } }
    function Remove-LocalUser { [CmdletBinding()] param($SID) $state.calls.Add('delete'); if (-not $state.deleteNoOp) { $state.users.Remove($SID.Value) } }
    function Set-TestBuildAccount {
        param([string] $Sid = 'S-1-5-21-1-2-3-500')
        $state.users.Clear(); $state.calls.Clear()
        $state.productType = 3; $state.renameNoOp = $false; $state.disableNoOp = $false; $state.deleteNoOp = $false
        $state.users[$Sid] = [pscustomobject]@{ Name = 'packer'; SID = [pscustomobject]@{ Value = $Sid }; Enabled = $true }
    }
    Set-TestBuildAccount
    $before = Get-WindowsImageBuildAccount
    if ($before.mode -ne 'BuiltinAdministrator' -or $state.calls.Count) { throw 'Account preflight mutated the host' }
    $cleanup = Remove-WindowsImageBuildAccount -Expected $before
    Assert-WindowsImageAccountCleanup -Cleanup $cleanup -GeneralizationState 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
    if (($state.calls -join ',') -ne 'rename,disable') { throw 'RID500 was deleted or left active' }
    $state.users[$cleanup.sid].Enabled = $true
    $rejected = $false
    try { Assert-WindowsImageAccountCleanup -Cleanup $cleanup -GeneralizationState 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' } catch { $rejected = $true }
    if (-not $rejected) { throw 'Capture accepted an active image administrator' }
    $state.users[$cleanup.sid].Enabled = $false
    $state.users[$cleanup.sid].SID.Value = 'S-1-5-21-4-5-6-500'
    $rejected = $false
    try { Assert-WindowsImageAccountCleanup -Cleanup $cleanup -GeneralizationState 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' } catch { $rejected = $true }
    if (-not $rejected) { throw 'Account readback accepted a different RID500 SID' }
    $state.users[$cleanup.sid].SID.Value = $cleanup.sid
    $rejected = $false
    try { Assert-WindowsImageAccountCleanup -Cleanup $cleanup -GeneralizationState 'IMAGE_STATE_COMPLETE' } catch { $rejected = $true }
    if (-not $rejected) { throw 'Capture accepted incomplete Sysprep' }

    Set-TestBuildAccount
    $before = Get-WindowsImageBuildAccount
    $state.users[$before.sid].Name = 'Administrator'
    $cleanup = Remove-WindowsImageBuildAccount -Expected $before
    Assert-WindowsImageAccountCleanup -Cleanup $cleanup -GeneralizationState 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
    if (($state.calls -join ',') -ne 'disable') { throw 'Canonical built-in account was renamed unnecessarily' }

    Set-TestBuildAccount -Sid 'S-1-5-21-1-2-3-1001'
    $cleanup = Remove-WindowsImageBuildAccount -Expected (Get-WindowsImageBuildAccount)
    Assert-WindowsImageAccountCleanup -Cleanup $cleanup -GeneralizationState 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
    if ($cleanup.mode -ne 'RemovedLocalUser' -or ($state.calls -join ',') -ne 'delete') { throw 'Ordinary build account was not deleted' }

    foreach ($scenario in @('client', 'special-rid', 'malformed-sid', 'name-collision', 'missing')) {
        Set-TestBuildAccount
        switch ($scenario) {
            'client' { $state.productType = 1 }
            'special-rid' { Set-TestBuildAccount -Sid 'S-1-5-21-1-2-3-501' }
            'malformed-sid' { Set-TestBuildAccount -Sid 'S-1-5-18' }
            'name-collision' { $state.users['other'] = [pscustomobject]@{ Name = 'Administrator'; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1002' }; Enabled = $true } }
            'missing' { $state.users.Clear() }
        }
        $rejected = $false
        try { Get-WindowsImageBuildAccount | Out-Null } catch { $rejected = $true }
        if (-not $rejected -or $state.calls.Count) { throw "Invalid cleanup preflight changed accounts: $scenario" }
    }
    foreach ($scenario in @('rename-no-op', 'disable-no-op', 'delete-no-op', 'identity-changed', 'sid-changed')) {
        Set-TestBuildAccount -Sid $(if ($scenario -eq 'delete-no-op') { 'S-1-5-21-1-2-3-1001' } else { 'S-1-5-21-1-2-3-500' })
        $before = Get-WindowsImageBuildAccount
        switch ($scenario) {
            'rename-no-op' { $state.renameNoOp = $true }
            'disable-no-op' { $state.disableNoOp = $true }
            'delete-no-op' { $state.deleteNoOp = $true }
            'identity-changed' { $state.users[$before.sid].Name = 'unexpected-account' }
            'sid-changed' { $state.users[$before.sid].SID.Value = 'S-1-5-21-4-5-6-500' }
        }
        $rejected = $false
        try { Remove-WindowsImageBuildAccount -Expected $before | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw "Account cleanup did not enforce readback: $scenario" }
    }
    Write-Output 'Windows image account SID classification, retirement, Server Sysprep gate, and failure readback tests passed.'
}
Test-WindowsImageAccountCleanup


function Test-WindowsFinalizationAttempt {
    . (Join-Path $PSScriptRoot 'Complete-WindowsRunnerImage.ps1')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('runner-finalization-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    try {
        $source = Join-Path $root 'source.ps1'
        [IO.File]::WriteAllText($source, '# fixture')
        $sha = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        $attempt = '11111111-1111-1111-1111-111111111111'
        foreach ($bad in @(@{ attempt = 'invalid'; sha = $sha }, @{ attempt = $attempt; sha = ('0' * 64) })) {
            $rejected = $false
            try { Start-WindowsImageFinalizationAttempt -Root $root -Attempt $bad.attempt -SourceSHA256 $bad.sha -SourcePath $source } catch { $rejected = $true }
            if (-not $rejected -or (Test-Path (Join-Path $root 'image-finalization.started.json'))) { throw 'Unverified source acquired a finalization attempt' }
        }
        Start-WindowsImageFinalizationAttempt -Root $root -Attempt $attempt -SourceSHA256 $sha -SourcePath $source
        foreach ($replay in @($attempt, '22222222-2222-2222-2222-222222222222')) {
            $rejected = $false
            try { Start-WindowsImageFinalizationAttempt -Root $root -Attempt $replay -SourceSHA256 $sha -SourcePath $source } catch { $rejected = $true }
            if (-not $rejected) { throw 'A second finalizer could repeat Sysprep' }
        }
        $record = @{ attemptId = $attempt; scriptSHA256 = $sha; status = 'Succeeded' }
        $record.attemptId = '22222222-2222-2222-2222-222222222222'
        $rejected = $false
        try { Complete-WindowsImageFinalizationAttempt -Root $root -Record $record } catch { $rejected = $true }
        if (-not $rejected -or (Test-Path (Join-Path $root 'image-finalization.complete.json'))) { throw 'Foreign attempt published completion' }
        $record.attemptId = $attempt
        Complete-WindowsImageFinalizationAttempt -Root $root -Record $record
        $saved = Get-Content -LiteralPath (Join-Path $root 'image-finalization.complete.json') -Raw | ConvertFrom-Json
        if ($saved.attemptId -cne $attempt -or $saved.scriptSHA256 -cne $sha) { throw 'Completion metadata changed' }
        $rejected = $false
        try { Complete-WindowsImageFinalizationAttempt -Root $root -Record $record } catch { $rejected = $true }
        if (-not $rejected) { throw 'Finalization completion was overwritten' }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    Write-Output 'Finalization source pin, atomic one-shot marker, replay rejection, and completion publication tests passed.'
}
Test-WindowsFinalizationAttempt



function Test-WindowsBatchPolicyRestoration {
    . (Join-Path $PSScriptRoot 'Complete-WindowsRunnerImage.ps1')
    # Compile P/Invoke declarations under the real .NET/PS5.1 toolchain only.
    # Every actual policy read/removal below is mocked; no LSA handle is opened.
    Initialize-WindowsBatchPolicyNative
    $policyFixture = @{ allow = @('S-1-5-32-544'); deny = @('S-1-5-32-546'); removals = 0; scenario = '' }
    $sid = 'S-1-5-21-1-2-3-500'; $attempt = '11111111-1111-1111-1111-111111111111'; $sha = 'a' * 64
    $root = Join-Path ([IO.Path]::GetTempPath()) ('runner-policy-test-' + [Guid]::NewGuid().ToString('N'))
    function Get-WindowsBatchLogonPolicy {
        if ($policyFixture.scenario -eq 'read-denied') { throw [UnauthorizedAccessException]::new('simulated policy read denial') }
        return @{ SeBatchLogonRight = @($policyFixture.allow); SeDenyBatchLogonRight = @($policyFixture.deny) }
    }
    function Remove-WindowsTemporaryBatchLogonAssignment {
        param($SID)
        if ($SID -cne 'S-1-5-21-1-2-3-500') { throw 'Attempted to change another account' }
        $policyFixture.removals++
        if ($policyFixture.scenario -eq 'remove-denied') { throw [UnauthorizedAccessException]::new('simulated policy removal denial') }
        if ($policyFixture.scenario -ne 'remove-no-op') { $policyFixture.allow = @($policyFixture.allow | Where-Object { $_ -cne $SID }) }
    }
    try {
        foreach ($scenario in @('unchanged', 'own-added', 'original-direct', 'reordered', 'unrelated-added', 'original-removed', 'deny-changed', 'read-denied', 'remove-denied', 'remove-no-op', 'ordinary-original-deleted')) {
            if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
            New-Item -ItemType Directory -Path $root | Out-Null
            $policyFixture.scenario = ''; $policyFixture.removals = 0; $policyFixture.allow = @('S-1-5-32-544'); $policyFixture.deny = @('S-1-5-32-546')
            if ($scenario -in @('original-direct', 'ordinary-original-deleted')) { $policyFixture.allow += $sid }
            Save-WindowsBatchLogonBaseline -Root $root -Attempt $attempt -SourceSHA256 $sha -SID $sid -Policy (Get-WindowsBatchLogonPolicy)
            switch ($scenario) {
                { $_ -in @('own-added', 'remove-denied', 'remove-no-op') } { $policyFixture.allow += $sid }
                'reordered' { $policyFixture.allow = @($sid, 'S-1-5-32-544') }
                'unrelated-added' { $policyFixture.allow += 'S-1-5-21-1-2-3-1002' }
                'original-removed' { $policyFixture.allow = @() }
                'deny-changed' { $policyFixture.deny = @() }
                'ordinary-original-deleted' { $policyFixture.allow = @('S-1-5-32-544') }
            }
            if ($scenario -eq 'own-added') {
                # Retry after successful-but-unacknowledged registration must
                # retain the pre-registration baseline, not bless the added SID.
                Save-WindowsBatchLogonBaseline -Root $root -Attempt $attempt -SourceSHA256 $sha -SID $sid -Policy (Get-WindowsBatchLogonPolicy)
                if ($sid -in (Read-WindowsBatchLogonBaseline -Root $root -Attempt $attempt -SourceSHA256 $sha).allow) { throw 'Staging retry replaced the original policy baseline' }
            }
            $policyFixture.scenario = $scenario
            $rejected = $false; $detail = ''
            try { Restore-WindowsBatchLogonBaseline -Root $root -Attempt $attempt -SourceSHA256 $sha } catch { $rejected = $true; $detail = $_.Exception.Message }
            $success = $scenario -in @('unchanged', 'own-added', 'original-direct', 'reordered')
            if ($rejected -eq $success) { throw "Unexpected policy restoration result: $scenario; $detail" }
            if ($scenario -in @('unchanged', 'original-direct', 'unrelated-added', 'original-removed', 'deny-changed', 'ordinary-original-deleted', 'read-denied') -and $policyFixture.removals) { throw 'Restoration changed an original or unrelated assignment' }
            if ($scenario -in @('own-added', 'reordered') -and ($policyFixture.removals -ne 1 -or $sid -in $policyFixture.allow)) { throw 'Temporary own-SID assignment was not removed exactly once' }
        }
    } finally { if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    Write-Output 'LSA declarations compile; baseline retry, direct-grant preservation, one-SID restoration, unrelated drift, and failure-readback tests passed.'
}
Test-WindowsBatchPolicyRestoration


function Test-WindowsTaskDefinitionReadback {
    . (Join-Path $PSScriptRoot 'Complete-WindowsRunnerImage.ps1')
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $expectedSID = $identity.User.Value
    $source = 'C:\Windows\Temp\Complete-WindowsRunnerImage.ps1'
    $attempt = '11111111-1111-1111-1111-111111111111'; $sha = 'a' * 64
    $executable = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = "-NoLogo -NoProfile -NonInteractive -File `"$source`" -AttemptId $attempt -ExpectedScriptSHA256 $sha"
    function New-TestTaskDefinition {
        return [pscustomobject]@{ Principal = [pscustomobject]@{ UserId = $expectedSID; LogonType = 'S4U'; RunLevel = 'Highest' }; Actions = @([pscustomobject]@{ Execute = $executable; Arguments = $arguments }); Triggers = $null; Settings = [pscustomobject]@{ ExecutionTimeLimit = 'PT18M'; MultipleInstances = 'IgnoreNew'; RestartCount = 0; AllowHardTerminate = $true } }
    }
    # Construct real CIM definitions in memory. These cmdlets do not register,
    # start, change, or delete any host task or policy.
    $definition = [pscustomobject]@{
        Principal = New-ScheduledTaskPrincipal -UserId $expectedSID -LogonType S4U -RunLevel Highest
        Actions = @(New-ScheduledTaskAction -Execute $executable -Argument $arguments)
        Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(18)) -MultipleInstances IgnoreNew
        Triggers = $null
    }
    $resolved = Assert-WindowsImageFinalizationTask -Task $definition -ExpectedSID $expectedSID -SourcePath $source -Attempt $attempt -SourceSHA256 $sha
    if ($resolved -cne $expectedSID) { throw 'CIM definition did not retain the exact principal SID' }
    foreach ($scenario in @('sid', 'account-name', 'numeric-enums', 'xml-runlevel', 'expanded-duration', 'seconds-duration')) {
        $definition = New-TestTaskDefinition
        switch ($scenario) {
            'account-name' { $definition.Principal.UserId = $identity.Name }
            'numeric-enums' { $definition.Principal.LogonType = [uint32]2; $definition.Principal.RunLevel = [uint32]1; $definition.Settings.MultipleInstances = [uint32]2 }
            'xml-runlevel' { $definition.Principal.RunLevel = 'HighestAvailable' }
            'expanded-duration' { $definition.Settings.ExecutionTimeLimit = 'P0DT0H18M0S' }
            'seconds-duration' { $definition.Settings.ExecutionTimeLimit = 'PT1080S' }
        }
        $resolved = Assert-WindowsImageFinalizationTask -Task $definition -ExpectedSID $expectedSID -SourcePath $source -Attempt $attempt -SourceSHA256 $sha
        if ($resolved -cne $expectedSID) { throw "Definition normalization changed identity: $scenario" }
    }
    $cases = @{
        'wrong-sid' = 'Principal.UserId'; 'missing-user' = 'Principal.UserId'; 'password-logon' = 'Principal.LogonType'
        'least-privilege' = 'Principal.RunLevel'; 'missing-actions' = 'Actions.Count'; 'extra-action' = 'Actions.Count'
        'wrong-executable' = 'Actions.Execute'; 'wrong-arguments' = 'Actions.Arguments'; 'trigger' = 'Triggers.Count'
        'unbounded' = 'Settings.ExecutionTimeLimit'; 'longer' = 'Settings.ExecutionTimeLimit'; 'invalid-duration' = 'Settings.ExecutionTimeLimit'
        'restart' = 'Settings.RestartCount'; 'missing-restart' = 'Settings.RestartCount'; 'parallel' = 'Settings.MultipleInstances'
        'no-hard-terminate' = 'Settings.AllowHardTerminate'; 'string-boolean' = 'Settings.AllowHardTerminate'; 'unknown-enum' = 'Principal.LogonType'
    }
    foreach ($scenario in $cases.Keys) {
        $definition = New-TestTaskDefinition
        switch ($scenario) {
            'wrong-sid' { $definition.Principal.UserId = 'S-1-5-21-1-2-3-1001' }
            'missing-user' { $definition.Principal.PSObject.Properties.Remove('UserId') }
            'password-logon' { $definition.Principal.LogonType = [uint32]1 }
            'least-privilege' { $definition.Principal.RunLevel = [uint32]0 }
            'missing-actions' { $definition.Actions = @() }
            'extra-action' { $definition.Actions += $definition.Actions[0] }
            'wrong-executable' { $definition.Actions[0].Execute = 'C:\DIAGNOSTIC_SECRET_CANARY\other.exe' }
            'wrong-arguments' { $definition.Actions[0].Arguments = 'DIAGNOSTIC_SECRET_CANARY' }
            'trigger' { $definition.Triggers = @('trigger') }
            'unbounded' { $definition.Settings.ExecutionTimeLimit = 'PT0S' }
            'longer' { $definition.Settings.ExecutionTimeLimit = 'PT18M1S' }
            'invalid-duration' { $definition.Settings.ExecutionTimeLimit = 'DIAGNOSTIC_SECRET_CANARY /not-a-duration' }
            'restart' { $definition.Settings.RestartCount = 1 }
            'missing-restart' { $definition.Settings.PSObject.Properties.Remove('RestartCount') }
            'parallel' { $definition.Settings.MultipleInstances = [uint32]0 }
            'no-hard-terminate' { $definition.Settings.AllowHardTerminate = $false }
            'string-boolean' { $definition.Settings.AllowHardTerminate = 'false' }
            'unknown-enum' { $definition.Principal.LogonType = 'DIAGNOSTIC_SECRET_CANARY' }
        }
        $errorMessage = ''
        try { Assert-WindowsImageFinalizationTask -Task $definition -ExpectedSID $expectedSID -SourcePath $source -Attempt $attempt -SourceSHA256 $sha | Out-Null } catch { $errorMessage = $_.Exception.Message }
        if (-not $errorMessage.Contains($cases[$scenario])) { throw "Task mismatch did not identify its field: $scenario" }
        if ($errorMessage.Contains('DIAGNOSTIC_SECRET_CANARY')) { throw 'Task diagnostics disclosed arbitrary task content' }
    }
    Write-Output 'Real in-memory Task Scheduler CIM definitions, SID/name and enum/duration normalization, exact action checks, and bounded mismatch diagnostics passed.'
}
Test-WindowsTaskDefinitionReadback

function Test-WindowsAdministratorFinalization {
    . (Join-Path $PSScriptRoot 'Complete-WindowsRunnerImage.ps1')
    $fixture = @{ scenario = ''; sid = 'S-1-5-21-1-2-3-500'; sha = ('a' * 64); attempt = '11111111-1111-1111-1111-111111111111'; system = $false; elevated = $true; exists = $false; runs = 0; ran = $false; registrations = 0; now = [DateTime]::UtcNow }
    $root = Join-Path ([IO.Path]::GetTempPath()) ('runner-task-test-' + [Guid]::NewGuid().ToString('N'))
    $source = 'C:\Windows\Temp\Complete-WindowsRunnerImage.ps1'
    $name = 'GitHubRunnerImageFinalize-' + $fixture.attempt.Replace('-', '')
    $executable = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = "-NoLogo -NoProfile -NonInteractive -File `"$source`" -AttemptId $($fixture.attempt) -ExpectedScriptSHA256 $($fixture.sha)"
    function Get-WindowsFinalizationIdentity { return [pscustomobject]@{ IsSystem = $fixture.system; User = [pscustomobject]@{ Value = $(if ($fixture.scenario -eq 'wrong-user') { 'S-1-5-21-1-2-3-1001' } else { $fixture.sid }) }; Groups = @([pscustomobject]@{ Value = 'S-1-5-32-544' }) } }
    function Test-WindowsFinalizationElevation { return $fixture.elevated }
    function Get-WindowsImageBuildAccount { return [pscustomobject]@{ mode = 'BuiltinAdministrator'; sid = $fixture.sid } }
    function Save-WindowsBatchLogonBaseline { param($Root, $Attempt, $SourceSHA256, $SID, $Policy) }
    function Read-WindowsBatchLogonBaseline { param($Root, $Attempt, $SourceSHA256) return [pscustomobject]@{ sid = $fixture.sid; allow = @('S-1-5-32-544'); deny = @() } }
    function Restore-WindowsBatchLogonBaseline { param($Root, $Attempt, $SourceSHA256) if ($fixture.scenario -eq 'policy-not-restored') { throw 'Policy readback failed' } }
    function Get-FileHash { param($LiteralPath, $Algorithm) return [pscustomobject]@{ Hash = $fixture.sha } }
    function Get-WindowsBatchLogonPolicy { return @{ SeBatchLogonRight = $(if ($fixture.scenario -eq 'missing-batch') { @() } else { @('S-1-5-32-544') }); SeDenyBatchLogonRight = $(if ($fixture.scenario -eq 'denied-batch') { @('S-1-5-32-544') } else { @() }) } }
    function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel } }
    function New-ScheduledTaskAction { param($Execute, $Argument) return [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
    function New-ScheduledTaskSettingsSet {
        param($ExecutionTimeLimit, $MultipleInstances)
        if ($ExecutionTimeLimit.TotalMinutes -ne 18 -or $MultipleInstances -ne 'IgnoreNew') { throw 'Unbounded or repeated administrator task' }
        return [pscustomobject]@{ ExecutionTimeLimit = 'PT18M'; MultipleInstances = 'IgnoreNew'; RestartCount = 0; AllowHardTerminate = $true }
    }
    function Register-ScheduledTask {
        [CmdletBinding()] param($TaskName, $Action, $Principal, $Settings)
        $fixture.registrations++; $fixture.exists = $true
        $fixture.task = [pscustomobject]@{ TaskName = $TaskName; Actions = @($Action); Principal = $Principal; Settings = $Settings; Triggers = $null; State = 'Ready' }
    }
    function Get-ScheduledTask {
        [CmdletBinding()] param($TaskName)
        $runtime = [pscustomobject]@{ TaskName = 'GitHubEphemeralRunner'; Principal = [pscustomobject]@{ UserId = 'SYSTEM' }; State = 'Ready' }
        if ($TaskName -eq 'GitHubEphemeralRunner') { return $runtime }
        if ($TaskName) { if (-not $fixture.exists) { throw 'Task missing' }; return $fixture.task }
        if ($fixture.exists) { $fixture.task }
        $runtime
    }
    function Get-ScheduledTaskInfo {
        [CmdletBinding()] param($TaskName)
        return [pscustomobject]@{ LastRunTime = $(if ($fixture.ran -and $fixture.scenario -ne 'unchanged-run') { [DateTime]'2021-01-01T00:00:00Z' } else { [DateTime]'2020-01-01T00:00:00Z' }); LastTaskResult = $(if ($fixture.scenario -eq 'nonzero-task') { 1 } else { 0 }) }
    }
    function Start-ScheduledTask { [CmdletBinding()] param($TaskName) $fixture.runs++; $fixture.ran = $true; if ($fixture.scenario -eq 'task-running') { $fixture.task.State = 'Running' } }
    function Stop-ScheduledTask { [CmdletBinding()] param($TaskName) $fixture.task.State = 'Ready' }
    function Unregister-ScheduledTask { [CmdletBinding(SupportsShouldProcess)] param($TaskName) if ($fixture.scenario -ne 'delete-no-op') { $fixture.exists = $false } }
    function Get-WindowsImageTaskTime { return $fixture.now }
    function Wait-WindowsImageTaskPoll { $fixture.now = $fixture.now.AddMinutes(10) }
    function Assert-WindowsImageAccountCleanup { param($Cleanup, $GeneralizationState) if ($fixture.scenario -eq 'account-remains' -or $GeneralizationState -cne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw 'Independent account/state readback failed' } }
    function Test-WindowsBuildCngKey { param($Identity) return $fixture.scenario -eq 'key-remains' }
    function Get-WindowsBuildKeyFile { param($Identity) if ($fixture.scenario -eq 'key-file-remains') { return 'file' } }
    function Get-ChildItem { [CmdletBinding()] param($Path, $LiteralPath, [switch] $Force) if ($LiteralPath -and $fixture.scenario -eq 'source-remains') { [pscustomobject]@{ Name = 'Complete-WindowsRunnerImage.ps1' } }; if ($fixture.scenario -eq 'certificate-remains' -and $Path -like 'Cert:*') { [pscustomobject]@{ Thumbprint = ('B' * 40); FriendlyName = 'GitHubRunnerPackerWinRM' } } }
    function Get-Service { [CmdletBinding()] param($Name) return [pscustomobject]@{ Status = 'Running' } }
    function Get-NetFirewallRule { [CmdletBinding()] param() if ($fixture.scenario -eq 'firewall-remains') { [pscustomobject]@{ Name = 'WINRM-Packer-Build' } } }
    function Get-ItemProperty { [CmdletBinding()] param($Path) return [pscustomobject]@{ ImageState = $(if ($fixture.scenario -eq 'incomplete-sysprep') { 'IMAGE_STATE_COMPLETE' } else { 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }); LocalAccountTokenFilterPolicy = $(if ($fixture.scenario -eq 'token-policy-remains') { 1 } else { 0 }) } }
    function Remove-Item { [CmdletBinding()] param($LiteralPath, [switch] $Force) if ($LiteralPath -cne $source) { throw 'Observer deleted an unrelated file' } }
    try {
        foreach ($scenario in @('normal', 'unapproved', 'system', 'wrong-user', 'not-elevated', 'missing-batch', 'denied-batch')) {
            $fixture.scenario = $scenario; $fixture.system = $scenario -eq 'system'; $fixture.elevated = $scenario -ne 'not-elevated'; $fixture.exists = $false; $fixture.registrations = 0
            $rejected = $false
            try { Register-WindowsImageFinalizationTask -Attempt $fixture.attempt -SourceSHA256 $fixture.sha -SourcePath $source -AllowTemporaryBatchLogonAssignment:($scenario -ne 'unapproved') | Out-Null } catch { $rejected = $true }
            if ($rejected -eq ($scenario -eq 'normal')) { throw "Unexpected administrator staging result: $scenario" }
            if ($scenario -ne 'normal' -and $fixture.registrations) { throw 'Invalid administrator context registered a task' }
            if ($scenario -eq 'normal') {
                Register-WindowsImageFinalizationTask -Attempt $fixture.attempt -SourceSHA256 $fixture.sha -SourcePath $source -AllowTemporaryBatchLogonAssignment:($scenario -ne 'unapproved') | Out-Null
                if ($fixture.registrations -ne 1 -or $fixture.runs) { throw 'Staging replay changed or launched the task' }
            }
        }
        foreach ($scenario in @('normal', 'bad-principal', 'bad-action', 'unbounded', 'restart', 'parallel', 'no-hard-terminate', 'trigger', 'nonzero-task', 'unchanged-run', 'task-running', 'missing-completion', 'wrong-execution-sid', 'incomplete-sysprep', 'account-remains', 'key-remains', 'key-file-remains', 'certificate-remains', 'firewall-remains', 'token-policy-remains', 'delete-no-op', 'source-remains', 'policy-not-restored')) {
            if (Test-Path -LiteralPath $root) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $root -Recurse -Force }
            New-Item -ItemType Directory -Path $root | Out-Null
            $fixture.scenario = $scenario; $fixture.system = $true; $fixture.exists = $true; $fixture.runs = 0; $fixture.ran = $false; $fixture.now = [DateTime]::UtcNow
            $fixture.task = [pscustomobject]@{ TaskName = $name; Principal = [pscustomobject]@{ UserId = $fixture.sid; LogonType = 'S4U'; RunLevel = 'Highest' }; Actions = @([pscustomobject]@{ Execute = $executable; Arguments = $arguments }); Settings = [pscustomobject]@{ ExecutionTimeLimit = 'PT18M'; MultipleInstances = 'IgnoreNew'; RestartCount = 0; AllowHardTerminate = $true }; Triggers = $null; State = 'Ready' }
            switch ($scenario) {
                'bad-principal' { $fixture.task.Principal.UserId = 'S-1-5-18' }
                'bad-action' { $fixture.task.Actions[0].Arguments = 'other' }
                'unbounded' { $fixture.task.Settings.ExecutionTimeLimit = 'PT0S' }
                'restart' { $fixture.task.Settings.RestartCount = 1 }
                'parallel' { $fixture.task.Settings.MultipleInstances = 'Parallel' }
                'no-hard-terminate' { $fixture.task.Settings.AllowHardTerminate = $false }
                'trigger' { $fixture.task.Triggers = @('recurring') }
            }
            $completion = @{ attemptId = $fixture.attempt; scriptSHA256 = $fixture.sha; status = 'Succeeded'; accountCleanup = @{ mode = 'BuiltinAdministrator'; sid = $fixture.sid }; keyIdentity = @{ thumbprint = ('A' * 40) } }
            if ($scenario -ne 'missing-completion') { $completion | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'image-finalization.complete.json') }
            @{ attemptId = $fixture.attempt; scriptSHA256 = $fixture.sha; executionSID = $(if ($scenario -eq 'wrong-execution-sid') { 'S-1-5-18' } else { $fixture.sid }) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'image-finalization.started.json')
            $rejected = $false; $detail = ''
            try { $result = Wait-WindowsImageFinalizationTask -Root $root -Attempt $fixture.attempt -SourceSHA256 $fixture.sha -SourcePath $source } catch { $rejected = $true; $detail = $_.Exception.Message }
            if ($rejected -eq ($scenario -eq 'normal')) { throw "Unexpected task observer result: $scenario; $detail" }
            if ($scenario -eq 'normal' -and ($fixture.exists -or $fixture.runs -ne 1 -or -not $result.finalizationTaskAbsent -or -not (Test-Path (Join-Path $root 'image-finalization.observed.json')))) { throw 'Task success lacked independent removal proof' }
            if ($scenario -in @('bad-principal', 'bad-action', 'unbounded', 'restart', 'parallel', 'no-hard-terminate', 'trigger') -and $fixture.runs) { throw 'Observer launched an untrusted task' }
            if ($scenario -ne 'normal' -and (Test-Path (Join-Path $root 'image-finalization.observed.json'))) { throw 'Observer published success after failed readback' }
        }
    } finally { if (Test-Path -LiteralPath $root) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $root -Recurse -Force } }
    Write-Output 'Administrator S4U staging, identity/elevation/policy gates, independent completion/readbacks, and task cleanup tests passed.'
}
Test-WindowsAdministratorFinalization


function Test-WindowsFinalizationFailureEvidence {
    . (Join-Path $PSScriptRoot 'Complete-WindowsRunnerImage.ps1')
    . (Join-Path $PSScriptRoot 'Invoke-WindowsImageFinalization.ps1')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('runner-failure-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $context = @{ root = $root; attempt = '11111111-1111-1111-1111-111111111111'; sha = ('a' * 64) }
    try {
        $failed = $false
        try { Invoke-WindowsFinalizationOperation $context 'listeners-remove' { throw [InvalidOperationException]::new('DIAGNOSTIC_SECRET_CANARY', [Runtime.InteropServices.COMException]::new('PRIVATE_INNER_MESSAGE', -2147024891)) } } catch { $failed = $true }
        if (-not $failed) { throw 'Operation wrapper suppressed the original error' }
        $first = Read-WindowsFinalizationFailure -Context $context
        if ($first.operation -cne 'listeners-remove' -or @($first.errors).Count -lt 2) { throw 'Original operation/native error chain was not captured' }
        # A subsequent cleanup error must not overwrite the first failure.
        try { Invoke-WindowsFinalizationOperation $context 'observer-cleanup' { throw 'SECONDARY_SECRET_CANARY' } } catch { }
        $record = Read-WindowsFinalizationFailure -Context $context
        if ($record.operation -cne 'listeners-remove') { throw 'Cleanup replaced the original failure' }
        $serialized = $record | ConvertTo-Json -Depth 5 -Compress
        if ($serialized.Length -gt 1500 -or $serialized -match 'SECRET_CANARY|PRIVATE_INNER_MESSAGE') { throw 'Failure telemetry leaked arbitrary content or exceeded its bound' }
        $record | Add-Member -NotePropertyName rawMessage -NotePropertyValue 'DIAGNOSTIC_SECRET_CANARY'
        $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'image-finalization.failure.json')
        $guestSafe = Read-WindowsFinalizationFailure -Context $context | ConvertTo-Json -Depth 5 -Compress
        if ($guestSafe -match 'rawMessage|SECRET_CANARY') { throw 'Guest emitted an unapproved telemetry field' }
        $line = 'GHA_IMAGE_FINALIZATION_FAILURE ' + ($record | ConvertTo-Json -Depth 5 -Compress)
        $hostSafe = Read-WindowsFinalizationFailureOutput -Output $line -ExpectedAttempt $context.attempt -ExpectedSHA256 $context.sha
        if ($hostSafe.operation -cne 'listeners-remove' -or ($hostSafe | ConvertTo-Json -Depth 5) -match 'rawMessage|SECRET_CANARY') { throw 'Host did not independently sanitize failure evidence' }
        if ($null -ne (Read-WindowsFinalizationFailureOutput -Output 'no failure record' -ExpectedAttempt $context.attempt -ExpectedSHA256 $context.sha)) { throw 'Missing diagnostics became evidence' }
        foreach ($scenario in @('attempt', 'source', 'operation', 'line', 'category', 'exception', 'hresult', 'too-long')) {
            $bad = $first | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            switch ($scenario) {
                'attempt' { $bad.attemptId = 'other' }
                'source' { $bad.scriptSHA256 = 'b' * 64 }
                'operation' { $bad.operation = 'unknown-operation' }
                'line' { $bad.sourceLine = '1' }
                'category' { $bad.category = 100 }
                'exception' { $bad.errors[0].type = 'DIAGNOSTIC_SECRET_CANARY' }
                'hresult' { $bad.errors[0].hresult = '0' }
            }
            $badText = $bad | ConvertTo-Json -Depth 5 -Compress
            if ($scenario -eq 'too-long') { $badText = 'x' * 2049 }
            $badText | Set-Content -LiteralPath (Join-Path $root 'image-finalization.failure.json')
            foreach ($reader in @('guest', 'host')) {
                $rejected = $false
                try {
                    if ($reader -eq 'guest') { Read-WindowsFinalizationFailure -Context $context | Out-Null }
                    else { Read-WindowsFinalizationFailureOutput -Output ('GHA_IMAGE_FINALIZATION_FAILURE ' + $badText) -ExpectedAttempt $context.attempt -ExpectedSHA256 $context.sha | Out-Null }
                } catch { $rejected = $true }
                if (-not $rejected) { throw "Invalid diagnostics accepted: $reader/$scenario" }
            }
        }
        foreach ($user in @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18')) {
            Assert-WindowsRuntimeTask -Task ([pscustomobject]@{ Principal = [pscustomobject]@{ UserId = $user }; State = 'Ready' })
        }
        foreach ($user in @('', 'S-1-5-21-1-2-3-1001')) {
            $rejected = $false
            try { Assert-WindowsRuntimeTask -Task ([pscustomobject]@{ Principal = [pscustomobject]@{ UserId = $user }; State = 'Ready' }) } catch { $rejected = $true }
            if (-not $rejected) { throw 'Runtime task accepted an unresolved or non-SYSTEM identity' }
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    Write-Output 'First-failure preservation, bounded native-code telemetry, guest/host sanitization, and exact runtime SYSTEM identity tests passed.'
}
Test-WindowsFinalizationFailureEvidence

function Test-WindowsFinalizationCleanupOrder {
    . (Join-Path $PSScriptRoot 'Complete-WindowsRunnerImage.ps1')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('runner-order-test-' + [Guid]::NewGuid().ToString('N'))
    $context = @{ root = $root; attempt = '11111111-1111-1111-1111-111111111111'; sha = ('a' * 64) }
    $order = [Collections.Generic.List[string]]::new()
    $orderState = @{ fail = ''; listeners = $true; firewall = $true; token = 1; retired = $false; generalized = $false }
    function Write-WindowsImageFinalizationPhase {
        param($Root, $Phase)
        $order.Add($Phase)
        if ($orderState.fail -ceq $Phase) { throw 'SIMULATED_PRIVATE_FAILURE' }
    }
    function Get-WindowsImageBuildAccount { return [pscustomobject]@{ mode = 'BuiltinAdministrator'; sid = 'S-1-5-21-1-2-3-500' } }
    function Get-WindowsImageBuildCertificate { return [pscustomobject]@{ thumbprint = ('A' * 40); provider = 'Microsoft Software Key Storage Provider'; machineKey = $true; keyName = 'owned'; uniqueName = 'owned-file' } }
    function Get-Service { [CmdletBinding()] param($Name) return [pscustomobject]@{ Status = 'Running' } }
    function Get-ChildItem { [CmdletBinding()] param($Path) if ($orderState.retired -or $orderState.generalized) { throw 'Worker used WSMan after credentials were retired' }; if ($orderState.listeners) { return 'owned-listener' } }
    function Remove-Item { [CmdletBinding()] param([Parameter(ValueFromPipeline)] $InputObject, [switch] $Recurse, [switch] $Force) process { $orderState.listeners = $false } }
    function Get-NetFirewallRule { [CmdletBinding()] param() if ($orderState.firewall) { return [pscustomobject]@{ Name = 'WINRM-Packer-Build' } } }
    function Remove-NetFirewallRule { [CmdletBinding()] param([Parameter(ValueFromPipeline)] $InputObject) process { $orderState.firewall = $false } }
    function New-ItemProperty { [CmdletBinding()] param($Path, $Name, $PropertyType, $Value, [switch] $Force) $orderState.token = $Value }
    function Get-ItemProperty { [CmdletBinding()] param($Path) return [pscustomobject]@{ LocalAccountTokenFilterPolicy = $orderState.token; ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' } }
    function Invoke-WindowsImageSysprep {
        if ($orderState.listeners -or $orderState.firewall -or $orderState.token -ne 0 -or $orderState.retired) { throw 'Sysprep preceded completed remoting cleanup' }
        $orderState.generalized = $true
    }
    function Remove-WindowsImageBuildCertificate { param($Identity) if (-not $orderState.generalized) { throw 'Certificate cleanup preceded Sysprep' }; return @{ privateKeyAbsent = $true; certificateAbsent = $true } }
    function Remove-WindowsImageBuildAccount { param($Expected) if (-not $orderState.generalized) { throw 'Account retirement preceded Sysprep' }; $orderState.retired = $true; return $Expected }
    function Assert-WindowsImageAccountCleanup { param($Cleanup, $GeneralizationState) if (-not $orderState.retired) { throw 'Account cleanup missing' } }
    try {
        foreach ($fail in @('', 'winrm-service-check', 'listeners-read', 'listeners-remove', 'firewall-read', 'firewall-remove', 'token-policy-restore', 'listeners-verify', 'firewall-verify', 'token-policy-verify')) {
            if (Test-Path $root) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $root -Recurse -Force }
            New-Item -ItemType Directory -Path $root | Out-Null
            $order.Clear(); $orderState.fail = $fail; $orderState.listeners = $true; $orderState.firewall = $true; $orderState.token = 1; $orderState.retired = $false; $orderState.generalized = $false
            $rejected = $false
            try { $result = Complete-WindowsImageBuildIdentity -Context $context } catch { $rejected = $true }
            if (-not $fail) {
                if ($rejected -or -not $orderState.retired -or -not $result.certificate.privateKeyAbsent -or $order.IndexOf('token-policy-verify') -gt $order.IndexOf('sysprep')) { throw 'Successful cleanup order changed' }
            } else {
                if (-not $rejected -or $orderState.generalized -or $orderState.retired) { throw "Failed remoting step continued to Sysprep: $fail" }
                if ((Read-WindowsFinalizationFailure -Context $context).operation -cne $fail) { throw "Failure lost its exact operation: $fail" }
            }
        }
    } finally { if (Test-Path $root) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $root -Recurse -Force } }
    Write-Output 'Remoting cleanup/readbacks precede Sysprep, key cleanup, and account retirement; failed steps cannot continue.'
}
Test-WindowsFinalizationCleanupOrder

function Test-WindowsManagedFinalization {
    . (Join-Path $PSScriptRoot 'Invoke-WindowsImageFinalization.ps1')
    $subscription = '00000000-0000-0000-0000-000000000000'
    $attempt = '11111111-1111-1111-1111-111111111111'
    $sha = 'a' * 64
    $vmId = "/subscriptions/$subscription/resourceGroups/packer-fixture/providers/Microsoft.Compute/virtualMachines/pkrvmfixture"
    $proof = @{ schemaVersion = 1; attemptId = $attempt; scriptSHA256 = $sha; status = 'Succeeded'; sysprepState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'; buildAccountRetired = $true; privateKeyAbsent = $true; certificateAbsent = $true; winrmListenersAbsent = $true; buildFirewallRuleAbsent = $true; tokenPolicyRestored = $true; runtimeTaskPresent = $true; finalizationTaskAbsent = $true; batchLogonPolicyRestored = $true }
    $testState = @{}
    function Get-WindowsFinalizationTime { return $testState.now }
    function Wait-WindowsFinalizationPoll { $testState.now = $testState.now.AddSeconds(60) }
    function Throw-TestAzureStatus {
        param([int] $Status)
        $simulatedFailure = [InvalidOperationException]::new('Simulated Azure response')
        $simulatedFailure.Data['StatusCode'] = $Status
        throw $simulatedFailure
    }
    function New-TestCommand {
        return [pscustomobject]@{
            tags = [pscustomobject]@{ 'finalization-attempt' = $attempt; 'finalizer-sha256' = $sha }
            properties = [pscustomobject]@{
                provisioningState = 'Succeeded'
                instanceView = [pscustomobject]@{ executionState = 'Succeeded'; exitCode = 0; output = ('GHA_IMAGE_FINALIZATION ' + ($proof | ConvertTo-Json -Compress)) }
            }
        }
    }
    function Invoke-WindowsImageRest {
        param($Method, $Uri, $Body)
        if ($Uri -like '*/permissions?*') {
            if ($testState.scenario -eq 'denied-permission-read') { Throw-TestAzureStatus 403 }
            $notActions = @()
            if ($testState.scenario -eq 'missing-permission') { $notActions = @('Microsoft.Compute/virtualMachines/runCommands/write') }
            return [pscustomobject]@{ value = @([pscustomobject]@{ actions = @('Microsoft.Compute/*'); notActions = $notActions }) }
        }
        if ($Uri -notlike '*/runCommands/*') {
            if ($Method -ne 'GET' -or $Uri -notlike "https://management.azure.com$vmId`?*") { throw 'Unexpected finalizer target' }
            return [pscustomobject]@{ id = $vmId; location = 'eastus2'; tags = [pscustomobject]@{ 'managed-by' = 'packer'; project = $(if ($testState.scenario -eq 'foreign-vm') { 'other' } else { 'github-actions-runners' }) }; properties = [pscustomobject]@{ storageProfile = [pscustomobject]@{ osDisk = [pscustomobject]@{ osType = 'Windows' } } } }
        }
        switch ($Method) {
            'PUT' {
                $testState.puts++
                if ($testState.puts -ne 1) { throw 'Finalization was resubmitted' }
                if (-not $Body.properties.asyncExecution -or $Body.properties.timeoutInSeconds -ne 1200 -or -not $Body.properties.treatFailureAsDeploymentFailure -or $Body.properties.ContainsKey('runAsPassword') -or $Body.properties.ContainsKey('outputBlobUri')) { throw 'Unexpected managed command execution or credential contract' }
                if ($Body.properties.source.script -notmatch 'Get-FileHash' -or $Body.properties.source.script -notmatch [regex]::Escape($sha)) { throw 'Guest finalizer source is not pinned' }
                if ($testState.scenario -eq 'put-denied') { Throw-TestAzureStatus 403 }
                if ($testState.scenario -ne 'put-missing') { $testState.exists = $true }
                if ($testState.scenario -in @('put-uncertain', 'put-missing')) { Throw-TestAzureStatus 0 }
                return
            }
            'DELETE' {
                $testState.deletes++
                if ($testState.scenario -ne 'delete-no-op') { $testState.exists = $false }
                if ($testState.scenario -eq 'delete-uncertain') { Throw-TestAzureStatus 0 }
                return
            }
            'GET' {
                if (-not $testState.exists) { Throw-TestAzureStatus 404 }
                $command = New-TestCommand
                if ($testState.scenario -eq 'foreign-command') { $command.tags.'finalization-attempt' = 'unrelated' }
                if ($Uri -like '*$expand=instanceView') {
                    $testState.polls++
                    if ($testState.scenario -eq 'throttled-read' -and $testState.polls -eq 1) { Throw-TestAzureStatus 429 }
                    if ($testState.scenario -in @('timeout', 'running-then-success') -and ($testState.scenario -eq 'timeout' -or $testState.polls -lt 3)) { $command.properties.instanceView.executionState = 'Running' }
                    if ($testState.scenario -eq 'failed-command') { $command.properties.instanceView.executionState = 'Failed'; $command.properties.instanceView.exitCode = 1 }
                    if ($testState.scenario -eq 'bad-proof') { $command.properties.instanceView.output = '' }
                    if ($testState.scenario -eq 'conflicting-failure') {
                        $failed = @{ schemaVersion = 1; status = 'Failed'; attemptId = $attempt; scriptSHA256 = $sha; operation = 'listeners-read'; sourceLine = 1; category = 0; errors = @(@{ type = 'System.Exception'; hresult = 0 }) }
                        $command.properties.instanceView.output += "`nGHA_IMAGE_FINALIZATION_FAILURE " + ($failed | ConvertTo-Json -Depth 5 -Compress)
                    }
                    if ($testState.scenario -eq 'malformed-failure') { $command.properties.instanceView.output += "`nGHA_IMAGE_FINALIZATION_FAILURE {}" }
                }
                return $command
            }
            default { throw 'Unexpected finalizer method' }
        }
    }
    foreach ($scenario in @('normal', 'put-uncertain', 'existing', 'running-then-success', 'throttled-read', 'delete-uncertain', 'missing-permission', 'denied-permission-read', 'foreign-vm', 'foreign-command', 'put-denied', 'put-missing', 'timeout', 'failed-command', 'bad-proof', 'conflicting-failure', 'malformed-failure', 'delete-no-op')) {
        $testState.Clear()
        $testState.scenario = $scenario; $testState.now = [DateTime]::UtcNow; $testState.puts = 0; $testState.deletes = 0; $testState.polls = 0; $testState.exists = $scenario -in @('existing', 'foreign-command')
        $rejected = $false
        $failureDetail = ''
        try { $result = Invoke-WindowsImageFinalization -Subscription $subscription -Group 'packer-fixture' -VM 'pkrvmfixture' -Region 'eastus2' -SourceSHA256 $sha -Attempt $attempt } catch { $rejected = $true; $failureDetail = $_.Exception.Message }
        $success = $scenario -in @('normal', 'put-uncertain', 'existing', 'running-then-success', 'throttled-read', 'delete-uncertain')
        if ($rejected -eq $success) { throw "Unexpected managed finalization result: $scenario; $failureDetail" }
        $expectedPuts = $(if ($scenario -in @('existing', 'missing-permission', 'denied-permission-read', 'foreign-vm', 'foreign-command')) { 0 } else { 1 })
        if ($testState.puts -ne $expectedPuts) { throw "Managed command submission count changed: $scenario" }
        if ($success -and ($testState.exists -or $testState.deletes -ne 1 -or $result.attemptId -cne $attempt)) { throw "Capture accepted unconfirmed cleanup: $scenario" }
        if ($scenario -eq 'foreign-command' -and $testState.deletes) { throw 'Deleted an unrelated command' }
        if ($scenario -eq 'timeout' -and ($testState.deletes -ne 1 -or $testState.exists)) { throw 'Timed-out command was not cancelled and removed' }
    }
    foreach ($scenario in @('nonzero', 'no-exit', 'running', 'bad-attempt', 'bad-sha', 'bad-sysprep', 'false-key', 'string-bool', 'missing-field', 'task-remains', 'policy-remains', 'empty-output', 'duplicate-proof')) {
        $command = New-TestCommand
        $record = $proof | ConvertTo-Json | ConvertFrom-Json
        switch ($scenario) {
            'nonzero' { $command.properties.instanceView.exitCode = 1 }
            'no-exit' { $command.properties.instanceView.PSObject.Properties.Remove('exitCode') }
            'running' { $command.properties.instanceView.executionState = 'Running' }
            'bad-attempt' { $record.attemptId = 'other' }
            'bad-sha' { $record.scriptSHA256 = 'b' * 64 }
            'bad-sysprep' { $record.sysprepState = 'IMAGE_STATE_COMPLETE' }
            'false-key' { $record.privateKeyAbsent = $false }
            'string-bool' { $record.privateKeyAbsent = 'true' }
            'missing-field' { $record.PSObject.Properties.Remove('privateKeyAbsent') }
            'task-remains' { $record.finalizationTaskAbsent = $false }
            'policy-remains' { $record.batchLogonPolicyRestored = $false }
        }
        $command.properties.instanceView.output = 'GHA_IMAGE_FINALIZATION ' + ($record | ConvertTo-Json -Compress)
        if ($scenario -eq 'empty-output') { $command.properties.instanceView.output = '' }
        if ($scenario -eq 'duplicate-proof') { $command.properties.instanceView.output += "`n" + $command.properties.instanceView.output }
        $rejected = $false
        try { Read-WindowsFinalizationProof -Command $command -ExpectedAttempt $attempt -ExpectedSHA256 $sha | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw "Unverified managed-command proof accepted: $scenario" }
    }
    Write-Output 'Managed finalization permissions, single submission, uncertain response, polling, proof, timeout, and cleanup tests passed.'
}
Test-WindowsManagedFinalization

function Test-WindowsImageCertificateCleanup {
    . (Join-Path $PSScriptRoot 'Complete-WindowsRunnerImage.ps1')
    $state = @{ provider = $true; file = $true; certificate = $true; scenario = ''; calls = [Collections.Generic.List[string]]::new() }
    function Test-WindowsBuildCngKey {
        param($Identity)
        if ($state.scenario -eq 'provider-access-denied') { throw [UnauthorizedAccessException]::new('simulated provider denial') }
        return $state.provider
    }
    function Get-ChildItem {
        [CmdletBinding()] param($Path, $LiteralPath, [switch] $Force)
        if ($LiteralPath) {
            if ($LiteralPath -ne "$env:ProgramData\Microsoft\Crypto\Keys") { throw 'Unexpected key directory' }
            if ($state.scenario -eq 'directory-access-denied') { throw [UnauthorizedAccessException]::new('simulated directory denial') }
            if ($state.file) {
                [pscustomobject]@{
                    Name = $(if ($state.scenario -eq 'case-variant') { 'OWNED-KEY-FILE' } else { 'owned-key-file' })
                    PSIsContainer = $state.scenario -eq 'directory-entry'
                    Attributes = $(if ($state.scenario -eq 'reparse-entry') { [IO.FileAttributes]::ReparsePoint } else { [IO.FileAttributes]::Normal })
                }
            }
            [pscustomobject]@{ Name = 'unrelated-key-file'; PSIsContainer = $false; Attributes = [IO.FileAttributes]::Normal }
        } elseif ($Path -eq 'Cert:\LocalMachine\My') {
            if ($state.certificate) { [pscustomobject]@{ Thumbprint = ('A' * 40); FriendlyName = 'GitHubRunnerPackerWinRM'; HasPrivateKey = $false } }
            [pscustomobject]@{ Thumbprint = ('B' * 40); FriendlyName = 'UnrelatedCertificate'; HasPrivateKey = $true }
        } else { throw 'Unexpected certificate path' }
    }
    function Remove-Item {
        [CmdletBinding()] param($Path, $LiteralPath, [switch] $Force)
        if ($LiteralPath -eq "$env:ProgramData\Microsoft\Crypto\Keys\owned-key-file") {
            $state.calls.Add('file-delete')
            if ($state.scenario -eq 'file-delete-denied') { throw [UnauthorizedAccessException]::new('simulated file deletion denial') }
            if ($state.scenario -ne 'file-delete-no-op') { $state.file = $false }
        } elseif ($Path -eq ('Cert:\LocalMachine\My\' + ('A' * 40))) {
            if ($state.provider -or $state.file) { throw 'Certificate was removed before private-key absence was proved' }
            $state.calls.Add('certificate-delete')
            if ($state.scenario -ne 'certificate-delete-no-op') { $state.certificate = $false }
        } else { throw 'Cleanup targeted an unrelated key or certificate' }
    }
    $key = [pscustomobject]@{ state = $state }
    $key | Add-Member ScriptMethod Delete {
        $this.state.calls.Add('provider-delete')
        if ($this.state.scenario -eq 'provider-delete-error') { throw [Security.Cryptography.CryptographicException]::new('simulated missing keyset') }
        if ($this.state.scenario -ne 'provider-delete-no-op') { $this.state.provider = $false; $this.state.file = $false }
    }
    $rsa = [pscustomobject]@{ state = $state }
    $rsa | Add-Member ScriptMethod Dispose { $this.state.calls.Add('handle-dispose') }
    $identity = [pscustomobject]@{ thumbprint = ('A' * 40); provider = 'Microsoft Software Key Storage Provider'; machineKey = $true; keyName = 'owned-key'; uniqueName = 'owned-key-file'; key = $key; rsa = $rsa }
    foreach ($scenario in @('normal', 'already-absent', 'provider-only', 'orphan-file', 'missing-certificate', 'case-variant')) {
        $state.scenario = $scenario; $state.calls.Clear(); $state.provider = $scenario -in @('normal', 'provider-only'); $state.file = $scenario -notin @('already-absent', 'provider-only'); $state.certificate = $scenario -ne 'missing-certificate'
        $result = Remove-WindowsImageBuildCertificate -Identity $identity
        if (-not $result.privateKeyAbsent -or -not $result.certificateAbsent -or $state.provider -or $state.file -or $state.certificate) { throw "Unproven key cleanup: $scenario" }
        if ($scenario -eq 'already-absent' -and ($state.calls.Contains('provider-delete') -or $state.calls.Contains('file-delete'))) { throw 'Already-absent key was not verified read-only' }
        if ($scenario -eq 'provider-only' -and -not $state.calls.Contains('provider-delete')) { throw 'A missing file hid a provider-accessible key' }
        if ($scenario -in @('orphan-file', 'missing-certificate', 'case-variant') -and -not $state.calls.Contains('file-delete')) { throw 'Certificate metadata hid a remaining private-key file' }
    }
    foreach ($scenario in @('provider-access-denied', 'directory-access-denied', 'provider-delete-error', 'provider-delete-no-op', 'file-delete-denied', 'file-delete-no-op', 'certificate-delete-no-op', 'directory-entry', 'reparse-entry')) {
        $state.scenario = $scenario; $state.calls.Clear(); $state.provider = $scenario -notin @('file-delete-denied', 'file-delete-no-op'); $state.file = $true; $state.certificate = $true
        $rejected = $false
        try { Remove-WindowsImageBuildCertificate -Identity $identity | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw "Key cleanup ignored an error or failed readback: $scenario" }
    }
    foreach ($field in @('provider', 'machineKey', 'uniqueName', 'thumbprint')) {
        $bad = [pscustomobject]@{ thumbprint = $identity.thumbprint; provider = $identity.provider; machineKey = $true; keyName = $identity.keyName; uniqueName = $identity.uniqueName; key = $key; rsa = $rsa }
        switch ($field) {
            'provider' { $bad.provider = 'Foreign Provider' }
            'machineKey' { $bad.machineKey = $false }
            'uniqueName' { $bad.uniqueName = '..\unrelated-key-file' }
            'thumbprint' { $bad.thumbprint = '*' }
        }
        $state.calls.Clear(); $rejected = $false
        try { Remove-WindowsImageBuildCertificate -Identity $bad | Out-Null } catch { $rejected = $true }
        if (-not $rejected -or $state.calls.Count) { throw "Invalid key identity reached deletion: $field" }
    }
    Write-Output 'Windows build certificate ownership, exact key-file cleanup, absence proof, and access/error readback tests passed.'
}
Test-WindowsImageCertificateCleanup

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $runner = Join-Path $testRoot 'runner'
    $state = Join-Path $testRoot 'state'
    New-Item -ItemType Directory -Path $runner, $state | Out-Null
    Set-Content -LiteralPath (Join-Path $runner 'run.cmd') -Value '@exit /b 0'
    $sha = '1150692afa94e71f872017e254ea55b6eece1eece3fe7e3a6d4c93d0a1b85cfc'
    $manifest = Join-Path $state 'manifest.json'
    @{ runnerVersion = '2.337.0'; runnerSHA256 = $sha } | ConvertTo-Json | Set-Content $manifest
    $payload = Join-Path $testRoot 'CustomData.bin'
    $data = @{ schemaVersion = 1; runnerVersion = '2.337.0'; runnerSHA256 = $sha; jitConfig = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('test-jit')) }
    $json = $data | ConvertTo-Json -Compress
    foreach ($text in @($json, [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))) {
        [IO.File]::WriteAllText($payload, $text)
        if ((Read-RunnerBootstrapData -Path $payload -ManifestPath $manifest) -cne 'test-jit') { throw 'JIT decode failed' }
    }
    foreach ($bad in @($json.Replace('2.337.0','2.1.0'), $json.Replace($sha, ('a' * 64)), $json.Replace('"schemaVersion":1','"schemaVersion":2'), '{"script":"Write-Output injected"}', ('x' * 65537))) {
        [IO.File]::WriteAllText($payload, $bad)
        $rejected = $false
        try { Read-RunnerBootstrapData -Path $payload -ManifestPath $manifest | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw 'Invalid payload was accepted' }
    }
    [IO.File]::WriteAllText($payload, $json)
    $code = Invoke-RunnerBootstrap -CustomDataPath $payload -RunnerRoot $runner -StateRoot $state -RunRunner {
        param($root)
        if (Test-Path $payload) { throw 'Payload is visible to the job' }
        if ($env:ACTIONS_RUNNER_INPUT_JITCONFIG -cne 'test-jit') { throw 'JIT environment missing' }
        return 17
    }
    if ($code -ne 17 -or (Test-Path Env:ACTIONS_RUNNER_INPUT_JITCONFIG)) { throw 'Exit status or credential cleanup failed' }
    $rejected = $false
    try { Invoke-RunnerBootstrap -CustomDataPath $payload -RunnerRoot $runner -StateRoot $state | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Reboot/duplicate startup can run a second job' }
    Remove-Item (Join-Path $state 'started')
    [IO.File]::WriteAllText($payload, $json)
    try { Invoke-RunnerBootstrap -CustomDataPath $payload -RunnerRoot $runner -StateRoot $state -RunRunner { throw 'simulated failure' } | Out-Null } catch { }
    if ((Test-Path $payload) -or (Test-Path Env:ACTIONS_RUNNER_INPUT_JITCONFIG)) { throw 'Failed runner leaked local credential' }
    Write-Output 'Windows bootstrap schema, image pinning, one-shot execution, exit status, and credential cleanup tests passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
