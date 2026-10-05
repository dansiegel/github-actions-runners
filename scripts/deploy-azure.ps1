[CmdletBinding()]
param(
    [ValidateSet('DryRun', 'Apply')]
    [string] $Mode = 'DryRun',
    [switch] $BootstrapOnly,
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,38}$')]
    [string] $GitHubOrganization,
    [string] $RunnerGroup = 'default',
    [string] $RunnerPoolsFile = '',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string] $RunnerScaleSetName = 'azure-linux',
    [ValidatePattern('^[0-9]+$')]
    [ValidateScript({ [decimal] $_ -le [int]::MaxValue })]
    [string] $RunnerMaxCapacity = '0',
    [string] $RunnerVmSize = 'Standard_D4s_v5',
    [ValidateSet('Regular', 'Spot')]
    [string] $RunnerVmPriority = 'Regular',
    [string[]] $RunnerLabels = @(),
    [string] $EnvironmentName = 'prod',
    [string] $Location = 'eastus2',
    [string] $ResourceGroup = 'gha-runners-prod',
    [string] $SshPublicKeyFile = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh\id_ed25519.pub'),
    [string] $RunnerImageId = '',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,39}$')]
    [string] $RunnerImageNamePrefix = 'gha-runner',
    [string] $ConfirmSubscription = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Get-NormalizedRunnerPools {
    if ([string]::IsNullOrWhiteSpace($RunnerPoolsFile)) {
        $labels = @($RunnerLabels | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($labels.Count -eq 0) { $labels = @($RunnerScaleSetName) }
        $sourcePools = @([pscustomobject]@{
            name       = $RunnerScaleSetName
            vmSize     = $RunnerVmSize
            maxRunners = [int] $RunnerMaxCapacity
            priority   = $RunnerVmPriority
            labels     = $labels
        })
    }
    else {
        if (-not (Test-Path -LiteralPath $RunnerPoolsFile -PathType Leaf)) {
            throw "Runner pool configuration not found: $RunnerPoolsFile"
        }
        $parsedPools = Get-Content -LiteralPath $RunnerPoolsFile -Raw | ConvertFrom-Json -NoEnumerate
        if ($parsedPools -isnot [Array]) {
            throw 'Runner pool configuration must be a JSON array'
        }
        $sourcePools = @($parsedPools)
    }

    if ($sourcePools.Count -lt 1) {
        throw 'Runner pool configuration must contain at least one pool'
    }

    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $allLabels = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $normalized = @()
    foreach ($pool in $sourcePools) {
        if ($pool -isnot [pscustomobject]) {
            throw 'Each runner pool must be a JSON object'
        }
        foreach ($property in $pool.PSObject.Properties.Name) {
            if ($property -cnotin @('name', 'vmSize', 'maxRunners', 'priority', 'labels', 'osDiskTier', 'enabled', 'imageId', 'osType', 'windowsAdminSecret')) {
                throw "Unknown runner pool configuration field: $property"
            }
        }
        $name = ([string] $pool.name).Trim()
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
            throw "Runner pool name '$name' must be 1-64 letters, numbers, dots, underscores, or hyphens"
        }
        if (-not $names.Add($name)) {
            throw "Runner pool name '$name' is duplicated"
        }

        $vmSize = ([string] $pool.vmSize).Trim()
        if ($vmSize -notmatch '^Standard_[A-Za-z0-9_]+$') {
            throw "Runner pool '$name' has an invalid Azure VM size: $vmSize"
        }

        $hasMaxRunners = $null -ne $pool.PSObject.Properties['maxRunners']
        if ($hasMaxRunners) {
            $value = $pool.maxRunners
            $numeric = $value -is [long] -or $value -is [int] -or $value -is [double] -or $value -is [decimal]
            if (-not $numeric -or $value -lt 0 -or $value -gt [int]::MaxValue -or [math]::Truncate($value) -ne $value) {
                throw "Runner pool '$name' maxRunners must be an integer from 0 through 2147483647"
            }
        }
        $hasEnabled = $null -ne $pool.PSObject.Properties['enabled']
        if ($hasEnabled -and $pool.enabled -isnot [bool]) {
            throw "Runner pool '$name' enabled must be a boolean"
        }
        $hasImageId = $null -ne $pool.PSObject.Properties['imageId']
        if ($hasImageId -and $pool.imageId -isnot [string]) {
            throw "Runner pool '$name' imageId must be a string"
        }

        $hasOSType = $null -ne $pool.PSObject.Properties['osType']
        if ($hasOSType -and ($pool.osType -isnot [string] -or $pool.osType -cnotin @('Linux', 'Windows'))) {
            throw "Runner pool '$name' osType must be Linux or Windows"
        }
        if ($pool.osType -ceq 'Windows' -and $pool.enabled -ne $false -and [string]::IsNullOrWhiteSpace([string] $pool.imageId)) {
            throw "Enabled Windows pool '$name' requires an explicit qualified imageId"
        }

        $hasWindowsSecret = $null -ne $pool.PSObject.Properties['windowsAdminSecret']
        if ($hasWindowsSecret) {
            $secret = $pool.windowsAdminSecret
            if ($pool.osType -cne 'Windows' -or $secret -isnot [pscustomobject] -or (@($secret.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'keyVaultId,secretName,secretVersion') {
                throw 'windowsAdminSecret requires exactly keyVaultId, secretName, secretVersion on a Windows profile'
            }
            if ($secret.keyVaultId -isnot [string] -or $secret.secretName -isnot [string] -or $secret.secretVersion -isnot [string] -or $secret.keyVaultId -cnotmatch '^/subscriptions/[A-Za-z0-9-]+/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft.KeyVault/vaults/[A-Za-z0-9-]+$' -or $secret.secretName -cnotmatch '^[A-Za-z0-9-]{1,127}$' -or $secret.secretVersion -cnotmatch '^[a-fA-F0-9]{32}$') {
                throw 'Invalid Windows Key Vault secret reference'
            }
        } elseif ($pool.osType -ceq 'Windows' -and $pool.enabled -ne $false) {
            throw 'Enabled Windows profiles require windowsAdminSecret'
        }

        $priority = if ($null -eq $pool.priority -or [string]::IsNullOrWhiteSpace([string] $pool.priority)) { 'Regular' } else { ([string] $pool.priority).Trim() }
        if ($priority -notin @('Regular', 'Spot')) {
            throw "Runner pool '$name' priority must be Regular or Spot"
        }

        $osDiskTier = ([string] $pool.osDiskTier).Trim()
        if ($osDiskTier -cnotin @('', 'P10', 'P15', 'P20', 'P30')) {
            throw "Runner pool '$name' osDiskTier must be P10, P15, P20, or P30"
        }

        $labels = @($pool.labels | ForEach-Object { ([string] $_).Trim() } | Where-Object { $_ })
        if ($labels.Count -eq 0) { $labels = @($name) }
        foreach ($label in $labels) {
            if (-not $allLabels.Add($label)) { throw "Runner label '$label' is duplicated across the pool configuration" }
        }
        $normalizedPool = [ordered]@{
            name       = $name
            vmSize     = $vmSize
            priority   = $priority
            osDiskTier = $osDiskTier
            labels     = $labels
        }
        if ($hasMaxRunners) { $normalizedPool.maxRunners = [int] $pool.maxRunners }
        if ($hasEnabled) { $normalizedPool.enabled = $pool.enabled }
        if ($hasImageId) { $normalizedPool.imageId = $pool.imageId.Trim() }
        if ($hasOSType) { $normalizedPool.osType = $pool.osType }
        if ($hasWindowsSecret) { $normalizedPool.windowsAdminSecret = $pool.windowsAdminSecret }
        $normalized += $normalizedPool
    }
    if (@($normalized | Where-Object { $_.enabled -ne $false }).Count -eq 0) {
        throw 'At least one runner pool must be enabled'
    }
    return $normalized
}

$runnerPools = @(Get-NormalizedRunnerPools)
$runnerPoolsJson = ConvertTo-Json -InputObject $runnerPools -Compress -Depth 5
$runnerPoolsBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($runnerPoolsJson))
$primaryPool = $runnerPools[0]

Write-Host "Target subscription: $SubscriptionId"
Write-Host "GitHub organization: $GitHubOrganization"
Write-Host "Resource group:      $ResourceGroup"
Write-Host "Location:            $Location"
Write-Host 'Runner controller:   one shared Container App (0.25 vCPU / 0.5 GiB)'
Write-Host 'Runner pools:'
foreach ($pool in $runnerPools) {
    $capacity = if ($pool.enabled -eq $false) { 'disabled' } elseif (-not $pool.maxRunners) { '0..demand (uncapped)' } else { "0..$($pool.maxRunners)" }
    Write-Host ("  {0}: {1} {2} ({3}); OS disk tier: {4}" -f $pool.name, $capacity, $pool.vmSize, $pool.priority, $(if ($pool.osDiskTier) { $pool.osDiskTier } else { 'default (128 GiB/P10)' }))
    $imageSource = if ($pool.imageId) { 'pool imageId override' } elseif ($pool.osType -ceq 'Windows') { 'unqualified Windows image (disabled)' } else { 'shared RUNNER_IMAGE_ID' }
    Write-Host ("  {0} labels: {1}; image: {2}" -f $pool.name, ($pool.labels -join ', '), $imageSource)
}
Write-Host 'Default Linux image: .NET 10, Node 24, Docker/Buildx, Azure CLI/Bicep, azd, PowerShell, Aspire'

Write-Host 'Windows profiles:    explicit qualified imageId required; image build is separate'

if ($Mode -ne 'Apply') {
    Write-Host 'Dry run only. No Azure resources were changed.'
    Write-Host "Apply with -Mode Apply -SubscriptionId $SubscriptionId -GitHubOrganization $GitHubOrganization -ConfirmSubscription $SubscriptionId"
    exit 0
}
if ($ConfirmSubscription -ne $SubscriptionId) {
    throw "Refusing Azure mutation: -ConfirmSubscription must exactly equal $SubscriptionId"
}
if (-not (Test-Path -LiteralPath $SshPublicKeyFile -PathType Leaf)) {
    throw "SSH public key not found: $SshPublicKeyFile"
}
foreach ($command in @('az', 'azd', 'packer', 'git')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required"
    }
}

az account set --subscription $SubscriptionId
foreach ($namespace in @('Microsoft.App', 'Microsoft.ContainerRegistry', 'Microsoft.KeyVault', 'Microsoft.Network', 'Microsoft.Compute', 'Microsoft.OperationalInsights')) {
    az provider register --namespace $namespace --subscription $SubscriptionId --wait
}
try {
    azd env select $EnvironmentName 2>$null
}
catch {
    azd env new $EnvironmentName --no-prompt
}

azd env set AZURE_SUBSCRIPTION_ID $SubscriptionId
azd env set AZURE_LOCATION $Location
azd env set AZURE_RESOURCE_GROUP $ResourceGroup
azd env set ADMIN_SSH_PUBLIC_KEY (Get-Content -LiteralPath $SshPublicKeyFile -Raw).Trim()
azd env set GITHUB_ORGANIZATION $GitHubOrganization
azd env set RUNNER_GROUP $RunnerGroup
azd env set RUNNER_SCALE_SET_NAME $primaryPool.name
azd env set RUNNER_MAX_CAPACITY ([string] [int] $primaryPool.maxRunners)
azd env set RUNNER_VM_SIZE $primaryPool.vmSize
azd env set RUNNER_VM_PRIORITY $primaryPool.priority
azd env set RUNNER_POOLS_JSON $runnerPoolsJson
azd env set RUNNER_POOLS_BASE64 $runnerPoolsBase64
azd env set RUNNER_IMAGE_ID $RunnerImageId
azd env set RUNNER_CONTROLLER_IMAGE ''
azd env set DEPLOY_RUNNER_CONTROLLER false
azd provision --environment $EnvironmentName --no-prompt

if ($BootstrapOnly) {
    Write-Host 'Bootstrap complete. Add the three GitHub App secrets shown in docs/operations.md, then rerun without -BootstrapOnly.'
    exit 0
}

$vaultName = azd env get-value GITHUB_APP_KEY_VAULT_NAME
$acrName = azd env get-value AZURE_CONTAINER_REGISTRY_NAME
foreach ($secretName in @('github-app-client-id', 'github-app-private-key', 'github-app-installation-id')) {
    az keyvault secret show --vault-name $vaultName --name $secretName --query id --output tsv | Out-Null
}

if ([string]::IsNullOrWhiteSpace($RunnerImageId)) {
    $imageName = '{0}-{1}' -f $RunnerImageNamePrefix, (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    packer init image/runner.pkr.hcl
    packer build `
        -var "subscription_id=$SubscriptionId" `
        -var "location=$Location" `
        -var "resource_group_name=$ResourceGroup" `
        -var "managed_image_name=$imageName" `
        image/runner.pkr.hcl
    $RunnerImageId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/images/$imageName"
}
else {
    $resolvedImageId = az resource show --ids $RunnerImageId --query id --output tsv
    if (-not [string]::Equals($resolvedImageId.Trim(), $RunnerImageId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Resolved runner image did not match -RunnerImageId'
    }
    Write-Host "Reusing managed runner image: $RunnerImageId"
}

$controllerRevision = (git rev-parse --short=12 HEAD 2>$null)
if ([string]::IsNullOrWhiteSpace($controllerRevision)) { $controllerRevision = 'local' }
$controllerTag = '{0}-{1}' -f $controllerRevision, (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
az acr build --registry $acrName --image "runner-controller:$controllerTag" --file controller/Dockerfile controller
$acrLoginServer = az acr show --name $acrName --query loginServer --output tsv

azd env set RUNNER_IMAGE_ID $RunnerImageId
azd env set RUNNER_CONTROLLER_IMAGE "$acrLoginServer/runner-controller:$controllerTag"
azd env set DEPLOY_RUNNER_CONTROLLER true
azd provision --environment $EnvironmentName --no-prompt

Write-Host ("Deployment complete. Workflow labels: {0}" -f (($runnerPools | Where-Object { $_.enabled -ne $false } | ForEach-Object { $_.labels }) -join ', '))
