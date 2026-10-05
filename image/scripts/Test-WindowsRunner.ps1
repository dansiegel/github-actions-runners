[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-WindowsRunner.ps1')

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
