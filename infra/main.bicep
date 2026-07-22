targetScope = 'subscription'

@description('Azure Developer CLI environment name.')
param environmentName string = 'prod'

@description('Azure region for the runner control plane and ephemeral VMs.')
param location string = 'eastus2'

@description('Resource group for the runner control plane and ephemeral VMs.')
param resourceGroupName string = 'gha-runners-${environmentName}'

@description('GitHub organization that owns the runner scale set.')
@minLength(1)
param githubOrganization string

@description('GitHub runner group. The GitHub App installation must be allowed to manage it.')
param runnerGroup string = 'default'

@description('Runner scale set name and workflow runs-on label. Used only when runnerPoolsJson is empty.')
@minLength(1)
param runnerScaleSetName string = 'azure-linux'

@description('Maximum concurrent ephemeral runner VMs. Used only when runnerPoolsJson is empty.')
@minValue(1)
@maxValue(20)
param maxRunners int = 10

@description('Azure VM size used for each ephemeral runner. Used only when runnerPoolsJson is empty.')
param runnerVmSize string = 'Standard_D4s_v5'

@description('Optional managed image or Compute Gallery image version resource ID. Empty uses Ubuntu 24.04 and bootstraps at startup.')
param runnerImageId string = ''

@description('Regular is reliable capacity. Spot is cheaper but jobs can be evicted. Used only when runnerPoolsJson is empty.')
@allowed([
  'Regular'
  'Spot'
])
param runnerVmPriority string = 'Regular'

@description('Optional JSON array of independently scaled runner pools. Each item accepts name, vmSize, maxRunners, priority, and labels. Empty uses the single-pool parameters for compatibility.')
param runnerPoolsJson string = ''

@description('Linux admin user for emergency access. The subnet NSG denies inbound Internet traffic.')
param adminUsername string = 'azureuser'

@description('SSH public key embedded in ephemeral runner VMs. This is not a secret.')
@minLength(40)
param adminSshPublicKey string

@description('Dedicated GitHub App Key Vault name.')
@minLength(3)
@maxLength(24)
param githubAppKeyVaultName string = toLower('kvgha${uniqueString(subscription().id, resourceGroupName, environmentName)}')

@description('ACR image reference for the controller. Populate with scripts/deploy-azure.sh before enabling deployment.')
param controllerContainerImage string = ''

@description('Deploy the always-on, low-resource queue controller. Keep false for phase-one bootstrap, then add Key Vault secrets and set true.')
param deployController bool = false

@description('Key Vault secret containing the GitHub App client ID (the numeric App ID also works).')
param githubAppClientIdSecretName string = 'github-app-client-id'

@description('Key Vault secret containing the GitHub App private key PEM.')
param githubAppPrivateKeySecretName string = 'github-app-private-key'

@description('Key Vault secret containing the GitHub App installation ID.')
param githubAppInstallationIdSecretName string = 'github-app-installation-id'

var tags = {
  project: 'github-actions-runners'
  environment: environmentName
  owner: githubOrganization
  'managed-by': 'azd'
}

var runnerPools = empty(runnerPoolsJson) ? [
  {
    name: runnerScaleSetName
    vmSize: runnerVmSize
    maxRunners: maxRunners
    priority: runnerVmPriority
    labels: [
      runnerScaleSetName
    ]
  }
] : json(runnerPoolsJson)

resource runnerResourceGroup 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module runnerInfra 'resources.bicep' = {
  name: 'github-actions-runners-${environmentName}'
  scope: runnerResourceGroup
  params: {
    location: location
    environmentName: environmentName
    githubOrganization: githubOrganization
    runnerGroup: runnerGroup
    runnerPools: runnerPools
    runnerImageId: runnerImageId
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    githubAppKeyVaultName: githubAppKeyVaultName
    controllerContainerImage: controllerContainerImage
    deployController: deployController
    githubAppClientIdSecretName: githubAppClientIdSecretName
    githubAppPrivateKeySecretName: githubAppPrivateKeySecretName
    githubAppInstallationIdSecretName: githubAppInstallationIdSecretName
    tags: tags
  }
}

output AZURE_RESOURCE_GROUP string = runnerResourceGroup.name
output AZURE_LOCATION string = location
output AZURE_CONTAINER_REGISTRY_NAME string = runnerInfra.outputs.containerRegistryName
output AZURE_CONTAINER_REGISTRY_LOGIN_SERVER string = runnerInfra.outputs.containerRegistryLoginServer
output GITHUB_APP_KEY_VAULT_NAME string = runnerInfra.outputs.githubAppKeyVaultName
output RUNNER_CONTROLLER_NAME string = runnerInfra.outputs.controllerName
output RUNNER_CONTROLLER_NAMES array = runnerInfra.outputs.controllerNames
output RUNNER_CONTROLLER_DEPLOYED bool = runnerInfra.outputs.controllerDeployed
output RUNNER_SCALE_SET_NAME string = runnerInfra.outputs.runnerScaleSetName
output RUNNER_SCALE_SET_NAMES array = runnerInfra.outputs.runnerScaleSetNames
output RUNNER_SUBNET_ID string = runnerInfra.outputs.runnerSubnetId
output RUNNER_MAX_CAPACITY int = runnerInfra.outputs.runnerMaxCapacity
output RUNNER_POOLS_JSON string = string(runnerPools)
