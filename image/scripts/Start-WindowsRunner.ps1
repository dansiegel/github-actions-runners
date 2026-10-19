# Baked into the qualified image; Azure CustomData.bin contains only JSON data.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-RunnerBootstrapData {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $ManifestPath)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 65536) { throw 'Custom data exceeds 64 KiB' }
    $text = [Text.Encoding]::UTF8.GetString($bytes).Trim([char]0xFEFF).Trim()
    # Windows agent versions can leave the envelope encoded. Accept one layer,
    # never arbitrary PowerShell or more than one nested encoding.
    if (-not $text.StartsWith('{')) { $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($text)) }
    $data = $text | ConvertFrom-Json
    $fields = @($data.PSObject.Properties.Name)
    if ($fields.Count -ne 4 -or @($fields | Where-Object { $_ -cnotin @('schemaVersion', 'runnerVersion', 'runnerSHA256', 'jitConfig') }).Count) { throw 'Invalid bootstrap fields' }
    if (($data.schemaVersion -isnot [int] -and $data.schemaVersion -isnot [long]) -or $data.schemaVersion -ne 1 -or $data.runnerVersion -isnot [string] -or $data.runnerVersion -cnotmatch '^\d+\.\d+\.\d+$' -or $data.runnerSHA256 -isnot [string] -or $data.runnerSHA256 -cnotmatch '^[a-f0-9]{64}$' -or $data.jitConfig -isnot [string]) { throw 'Invalid bootstrap schema' }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($manifest.runnerVersion -cne $data.runnerVersion -or $manifest.runnerSHA256 -cne $data.runnerSHA256) { throw 'Image runner version/checksum does not match controller; rebuild and qualify the image' }
    $jit = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data.jitConfig))
    if ([string]::IsNullOrWhiteSpace($jit)) { throw 'Empty JIT configuration' }
    return $jit
}

function Invoke-RunnerBootstrap {
    param(
        [string] $CustomDataPath = "$env:SystemDrive\AzureData\CustomData.bin",
        [string] $RunnerRoot = "$env:SystemDrive\actions-runner",
        [string] $StateRoot = "$env:ProgramData\GitHubRunner",
        [scriptblock] $RunRunner = { param($root) Push-Location $root; try { & .\run.cmd | Out-Host; return $LASTEXITCODE } finally { Pop-Location } }
    )
    # FileMode.CreateNew is the durable one-shot guard, including after reboot.
    $ownsRun = $false
    try {
        $marker = [IO.File]::Open((Join-Path $StateRoot 'started'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $marker.Dispose()
        $ownsRun = $true
        $jit = Read-RunnerBootstrapData -Path $CustomDataPath -ManifestPath (Join-Path $StateRoot 'manifest.json')
        if (-not (Test-Path -LiteralPath (Join-Path $RunnerRoot 'run.cmd') -PathType Leaf)) { throw 'Baked runner is missing' }
        if (Test-Path -LiteralPath (Join-Path $RunnerRoot '.runner')) { throw 'Image contains an already configured runner' }
        # Delete the credential-bearing local payload before any job can start.
        Remove-Item -LiteralPath $CustomDataPath -Force
        $env:ACTIONS_RUNNER_INPUT_JITCONFIG = $jit
        $jit = $null
        $env:RUNNER_ALLOW_RUNASROOT = '1'
        $code = & $RunRunner $RunnerRoot
        return [int] $code
    } finally {
        Remove-Item Env:ACTIONS_RUNNER_INPUT_JITCONFIG -ErrorAction SilentlyContinue
        if ($ownsRun) { Remove-Item -LiteralPath $CustomDataPath -Force -ErrorAction SilentlyContinue }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    $stateRoot = "$env:ProgramData\GitHubRunner"
    try {
        $deadline = [DateTime]::UtcNow.AddMinutes(15)
        $payload = "$env:SystemDrive\AzureData\CustomData.bin"
        while (-not (Test-Path -LiteralPath $payload)) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for Azure custom data' }
            Start-Sleep -Seconds 5
        }
        # The image builder's remoting listener must not survive into a job.
        Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
        Stop-Service WinRM -Force -ErrorAction SilentlyContinue
        Set-Service WinRM -StartupType Disabled
        Get-NetFirewallRule -Name 'WINRM*', 'RemoteDesktop*' -ErrorAction SilentlyContinue | Disable-NetFirewallRule | Out-Null
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1
        if (Get-LocalUser -Name 'packer' -ErrorAction SilentlyContinue) { throw 'Image still contains its build account' }
        $exitCode = Invoke-RunnerBootstrap
    } catch {
        # Do not log exception text: malformed payloads can contain JIT data.
        Write-Output 'Windows runner bootstrap failed; inspect image/version, payload availability, and runner diagnostics.'
    } finally {
        try {
            @{ completedUtc = [DateTime]::UtcNow.ToString('o'); exitCode = $exitCode } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateRoot 'result.json')
        } finally { & shutdown.exe /s /t 0 /f }
    }
    exit $exitCode
}
