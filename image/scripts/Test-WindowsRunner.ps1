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
