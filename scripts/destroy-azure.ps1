[CmdletBinding()]
param(
    [ValidateSet('DryRun', 'Apply')]
    [string] $Mode = 'DryRun',
    [string] $ResourceGroup = 'gha-runners-prod',
    [string] $ConfirmSubscription = '',
    [string] $ConfirmResourceGroup = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$subscriptionId = 'd901cbec-f20d-4272-a0b4-9ee06b850880'
Write-Host "Would delete resource group $ResourceGroup from subscription $subscriptionId."
Write-Warning 'Key Vault purge protection can leave the vault name unavailable after resource-group deletion.'

if ($Mode -ne 'Apply') {
    Write-Host 'Dry run only. Nothing was deleted.'
    exit 0
}
if ($ConfirmSubscription -ne $subscriptionId) {
    throw "-ConfirmSubscription must exactly equal $subscriptionId"
}
if ($ConfirmResourceGroup -ne $ResourceGroup) {
    throw "-ConfirmResourceGroup must exactly equal $ResourceGroup"
}

az account set --subscription $subscriptionId
$actualId = az group show --name $ResourceGroup --query id --output tsv
$expectedId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup"
if (-not [string]::Equals($actualId.Trim(), $expectedId, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Resolved resource group did not match expected ID; refusing deletion'
}
az group delete --name $ResourceGroup --subscription $subscriptionId --yes --no-wait
Write-Host "Deletion requested for exactly $expectedId"
