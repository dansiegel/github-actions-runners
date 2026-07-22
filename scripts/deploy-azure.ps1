[CmdletBinding()]
param(
    [ValidateSet('DryRun', 'Apply')]
    [string] $Mode = 'DryRun',
    [switch] $BootstrapOnly,
    [string] $EnvironmentName = 'prod',
    [string] $Location = 'eastus2',
    [string] $ResourceGroup = 'gha-runners-prod',
    [string] $SshPublicKeyFile = "$HOME/.ssh/id_ed25519.pub",
    [string] $RunnerImageId = '',
    [string] $ConfirmSubscription = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$subscriptionId = 'd901cbec-f20d-4272-a0b4-9ee06b850880'

Write-Host "Target subscription: $subscriptionId"
Write-Host "Resource group:      $ResourceGroup"
Write-Host "Location:            $Location"
Write-Host 'Runner scale set:    avp-linux'
Write-Host 'Runner capacity:     0 to 12 Standard_D4s_v5 VMs'
Write-Host 'Runner image:        .NET 10, Node 24, Docker/Buildx, Azure CLI, azd, PowerShell, Aspire'

if ($Mode -ne 'Apply') {
    Write-Host 'Dry run only. No Azure resources were changed.'
    Write-Host "Apply with -Mode Apply -ConfirmSubscription $subscriptionId"
    exit 0
}
if ($ConfirmSubscription -ne $subscriptionId) {
    throw "Refusing Azure mutation: -ConfirmSubscription must exactly equal $subscriptionId"
}
if (-not (Test-Path -LiteralPath $SshPublicKeyFile -PathType Leaf)) {
    throw "SSH public key not found: $SshPublicKeyFile"
}
foreach ($command in @('az', 'azd', 'packer', 'git')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required"
    }
}

az account set --subscription $subscriptionId
foreach ($namespace in @('Microsoft.App', 'Microsoft.ContainerRegistry', 'Microsoft.KeyVault', 'Microsoft.Network', 'Microsoft.Compute', 'Microsoft.OperationalInsights')) {
    az provider register --namespace $namespace --subscription $subscriptionId --wait
}
try {
    azd env select $EnvironmentName 2>$null
}
catch {
    azd env new $EnvironmentName --no-prompt
}

azd env set AZURE_SUBSCRIPTION_ID $subscriptionId
azd env set AZURE_LOCATION $Location
azd env set AZURE_RESOURCE_GROUP $ResourceGroup
azd env set ADMIN_SSH_PUBLIC_KEY (Get-Content -LiteralPath $SshPublicKeyFile -Raw).Trim()
azd env set GITHUB_ORGANIZATION AvantiPoint
azd env set RUNNER_GROUP default
azd env set RUNNER_SCALE_SET_NAME avp-linux
azd env set RUNNER_MAX_CAPACITY 12
azd env set RUNNER_VM_SIZE Standard_D4s_v5
azd env set RUNNER_VM_PRIORITY Regular
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
    $imageName = 'gha-runner-{0}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    packer init image/runner.pkr.hcl
    packer build `
        -var "subscription_id=$subscriptionId" `
        -var "location=$Location" `
        -var "resource_group_name=$ResourceGroup" `
        -var "managed_image_name=$imageName" `
        image/runner.pkr.hcl
    $RunnerImageId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/images/$imageName"
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

Write-Host 'Deployment complete. Workflows can now target: runs-on: avp-linux'
