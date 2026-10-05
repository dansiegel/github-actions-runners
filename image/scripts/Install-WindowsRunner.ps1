[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($env:RUNNER_VERSION -cnotmatch '^\d+\.\d+\.\d+$' -or $env:RUNNER_SHA256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Pinned Windows runner version/checksum required' }
$stateRoot = "$env:ProgramData\GitHubRunner"
$runnerRoot = "$env:SystemDrive\actions-runner"
$downloads = "$env:TEMP\runner-image-downloads"
New-Item -ItemType Directory -Force -Path $stateRoot, $runnerRoot, $downloads | Out-Null
& icacls.exe $stateRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot secure bootstrap state directory' }
Copy-Item -LiteralPath 'C:\Windows\Temp\Start-WindowsRunner.ps1' -Destination $stateRoot
Remove-Item -LiteralPath 'C:\Windows\Temp\Start-WindowsRunner.ps1'

function Get-VerifiedDownload {
    param([string] $Url, [string] $Name, [string] $Hash, [string] $Algorithm = 'SHA256')
    $path = Join-Path $downloads $Name
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $path
    if ((Get-FileHash -LiteralPath $path -Algorithm $Algorithm).Hash -ine $Hash) { throw "Checksum mismatch: $Name" }
    return $path
}
function Install-CheckedProcess {
    param([string] $Path, [string[]] $Arguments)
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "Installer failed with exit code $($process.ExitCode)" }
}

$archive = Get-VerifiedDownload -Url "https://github.com/actions/runner/releases/download/v$env:RUNNER_VERSION/actions-runner-win-x64-$env:RUNNER_VERSION.zip" -Name 'runner.zip' -Hash $env:RUNNER_SHA256
Expand-Archive -LiteralPath $archive -DestinationPath $runnerRoot

# Lightweight, pinned command-line toolchain. No Visual Studio/Build Tools EULA,
# Windows SDK workload, Docker Desktop, or activation workaround is installed.
$git = Get-VerifiedDownload -Url 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.1/Git-2.56.0-64-bit.exe' -Name 'git.exe' -Hash 'bfe94e7b419b16eee9fecbd1253a98e3d4f49ba8f029630549052278ffe286a6'
Install-CheckedProcess -Path $git -Arguments @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS')
$pwsh = Get-VerifiedDownload -Url 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.msi' -Name 'powershell.msi' -Hash '958838ff55091e1c8705d89efed0cc7e8245a3a6ef6c0ccfae20015227108ad8'
Install-CheckedProcess -Path 'msiexec.exe' -Arguments @('/i', $pwsh, '/qn', '/norestart', 'ENABLE_PSREMOTING=0', 'REGISTER_MANIFEST=0', 'USE_MU=0', 'ENABLE_MU=0')

# Versioned vendor metadata supplies the pinned SDK archive hash, never a
# floating install script. The resolved file and hash are written to the image manifest.
$metadata = Invoke-RestMethod -Uri 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'
$sdk = @($metadata.releases | ForEach-Object { $_.sdks } | Where-Object { $_.version -eq '10.0.401' })[0]
$dotnetFile = @($sdk.files | Where-Object { $_.rid -eq 'win-x64' -and $_.url.EndsWith('.zip') })[0]
if ($dotnetFile.url -notlike 'https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.401/*') { throw 'Unexpected SDK source' }
$dotnet = Get-VerifiedDownload -Url $dotnetFile.url -Name 'dotnet.zip' -Hash $dotnetFile.hash -Algorithm SHA512
New-Item -ItemType Directory -Force -Path "$env:ProgramFiles\dotnet" | Out-Null
Expand-Archive -LiteralPath $dotnet -DestinationPath "$env:ProgramFiles\dotnet"
$nodeChecksums = (Invoke-WebRequest -UseBasicParsing -Uri 'https://nodejs.org/dist/v24.21.0/SHASUMS256.txt').Content
$nodeHash = [regex]::Match($nodeChecksums, '(?m)^([a-f0-9]{64})\s+node-v24\.21\.0-win-x64\.zip\s*$').Groups[1].Value
if (-not $nodeHash) { throw 'Pinned Node archive checksum unavailable' }
$node = Get-VerifiedDownload -Url 'https://nodejs.org/dist/v24.21.0/node-v24.21.0-win-x64.zip' -Name 'node.zip' -Hash $nodeHash
Expand-Archive -LiteralPath $node -DestinationPath $downloads
Move-Item -LiteralPath (Join-Path $downloads 'node-v24.21.0-win-x64') -Destination "$env:ProgramFiles\nodejs"
$path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
[Environment]::SetEnvironmentVariable('Path', "$env:ProgramFiles\dotnet;$env:ProgramFiles\nodejs;$path", 'Machine')
[Environment]::SetEnvironmentVariable('DOTNET_ROOT', "$env:ProgramFiles\dotnet", 'Machine')
[Environment]::SetEnvironmentVariable('DOTNET_NOLOGO', '1', 'Machine')

@{
    os = 'Windows'; baseImage = "MicrosoftWindowsServer:WindowsServer:2025-datacenter:$env:BASE_IMAGE_VERSION"
    runnerVersion = $env:RUNNER_VERSION; runnerSHA256 = $env:RUNNER_SHA256
    dotnet = '10.0.401'; dotnetSHA512 = $dotnetFile.hash
    node = '24.21.0'; nodeSHA256 = $nodeHash
    git = '2.56.0.windows.1'; powershell = '7.6.6'; visualStudioBuildTools = $false
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateRoot 'manifest.json')
Remove-Item -LiteralPath $downloads -Recurse -Force
# Register the startup task only after the build reboot and verification.
