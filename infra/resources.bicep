targetScope = 'resourceGroup'

param location string
param environmentName string
param githubOrganization string
param runnerGroup string
param runnerScaleSetName string

@minValue(1)
@maxValue(20)
param maxRunners int

param runnerVmSize string
param runnerImageId string

@allowed([
  'Regular'
  'Spot'
])
param runnerVmPriority string

param adminUsername string
param adminSshPublicKey string
param githubAppKeyVaultName string
param controllerContainerImage string
param deployController bool
param githubAppClientIdSecretName string
param githubAppPrivateKeySecretName string
param githubAppInstallationIdSecretName string
param tags object

var resourceToken = take(toLower(replace(environmentName, '-', '')), 12)
var containerRegistryName = take(toLower('acrgha${uniqueString(subscription().id, resourceGroup().id)}'), 50)
var controllerName = take('gha-scale-controller-${resourceToken}', 32)
var controllerIdentityName = take('gha-scale-controller-${resourceToken}-mi', 128)
var managedEnvironmentName = take('gha-runners-${resourceToken}-cae', 32)
var runnerVnetName = 'gha-runners-${resourceToken}-vnet'
var runnerSubnetName = 'runners'
var runnerSubnetAddressPrefix = '10.42.1.0/24'
var runnerVersion = '2.335.1'
var runnerSha256 = '4ef2f25285f0ae4477f1fe1e346db76d2f3ebf03824e2ddd1973a2819bf6c8cf'

resource runnerNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'gha-runners-${resourceToken}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'DenyInternetInbound'
        properties: {
          priority: 100
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource runnerVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: runnerVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.42.0.0/16'
      ]
    }
    subnets: [
      {
        name: runnerSubnetName
        properties: {
          addressPrefix: runnerSubnetAddressPrefix
          networkSecurityGroup: {
            id: runnerNetworkSecurityGroup.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource githubAppVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: githubAppKeyVaultName
  location: location
  tags: union(tags, {
    purpose: 'github-app-controller-secrets'
    'runner-secret-access': 'none'
  })
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 7
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource controllerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: controllerIdentityName
  location: location
  tags: tags
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: containerRegistryName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'gha-runners-${resourceToken}-logs'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: managedEnvironmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    zoneRedundant: false
  }
}

resource runnerLifecycleRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 'gha-ephemeral-runner-lifecycle')
  properties: {
    roleName: 'GitHub ephemeral runner lifecycle (${environmentName})'
    description: 'Can create, inspect, and delete only the Azure resource types used by ephemeral GitHub runner VMs.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Compute/virtualMachines/read'
          'Microsoft.Compute/virtualMachines/write'
          'Microsoft.Compute/virtualMachines/delete'
          'Microsoft.Compute/virtualMachines/instanceView/read'
          'Microsoft.Compute/disks/read'
          'Microsoft.Compute/disks/write'
          'Microsoft.Compute/disks/delete'
          'Microsoft.Compute/images/read'
          'Microsoft.Compute/galleries/images/versions/read'
          'Microsoft.Compute/locations/publishers/artifacttypes/offers/skus/versions/read'
          'Microsoft.Network/networkInterfaces/read'
          'Microsoft.Network/networkInterfaces/write'
          'Microsoft.Network/networkInterfaces/delete'
          'Microsoft.Network/networkInterfaces/join/action'
          'Microsoft.Network/publicIPAddresses/read'
          'Microsoft.Network/publicIPAddresses/write'
          'Microsoft.Network/publicIPAddresses/delete'
          'Microsoft.Network/publicIPAddresses/join/action'
          'Microsoft.Network/virtualNetworks/subnets/read'
          'Microsoft.Network/virtualNetworks/subnets/join/action'
          'Microsoft.Resources/subscriptions/resourceGroups/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [
      resourceGroup().id
    ]
  }
}

resource runnerLifecycleRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, controllerIdentity.id, runnerLifecycleRole.id)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: runnerLifecycleRole.id
    principalId: controllerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource keyVaultSecretsUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(githubAppVault.id, controllerIdentity.id, 'Key Vault Secrets User')
  scope: githubAppVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: controllerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, controllerIdentity.id, 'AcrPull')
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: controllerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource runnerController 'Microsoft.App/containerApps@2024-03-01' = if (deployController) {
  name: controllerName
  location: location
  tags: union(tags, {
    purpose: 'github-runner-scale-set-listener'
    'runner-min-capacity': '0'
    'runner-max-capacity': string(maxRunners)
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${controllerIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: controllerIdentity.id
        }
      ]
      secrets: [
        {
          name: 'github-app-client-id'
          keyVaultUrl: '${githubAppVault.properties.vaultUri}secrets/${githubAppClientIdSecretName}'
          identity: controllerIdentity.id
        }
        {
          name: 'github-app-private-key'
          keyVaultUrl: '${githubAppVault.properties.vaultUri}secrets/${githubAppPrivateKeySecretName}'
          identity: controllerIdentity.id
        }
        {
          name: 'github-app-installation-id'
          keyVaultUrl: '${githubAppVault.properties.vaultUri}secrets/${githubAppInstallationIdSecretName}'
          identity: controllerIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'scale-controller'
          image: controllerContainerImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'GITHUB_CONFIG_URL'
              value: 'https://github.com/${githubOrganization}'
            }
            {
              name: 'RUNNER_SCALE_SET_NAME'
              value: runnerScaleSetName
            }
            {
              name: 'RUNNER_LABELS'
              value: runnerScaleSetName
            }
            {
              name: 'RUNNER_GROUP'
              value: runnerGroup
            }
            {
              name: 'MIN_RUNNERS'
              value: '0'
            }
            {
              name: 'MAX_RUNNERS'
              value: string(maxRunners)
            }
            {
              name: 'GITHUB_APP_CLIENT_ID'
              secretRef: 'github-app-client-id'
            }
            {
              name: 'GITHUB_APP_PRIVATE_KEY'
              secretRef: 'github-app-private-key'
            }
            {
              name: 'GITHUB_APP_INSTALLATION_ID'
              secretRef: 'github-app-installation-id'
            }
            {
              name: 'AZURE_SUBSCRIPTION_ID'
              value: subscription().subscriptionId
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: controllerIdentity.properties.clientId
            }
            {
              name: 'AZURE_RESOURCE_GROUP'
              value: resourceGroup().name
            }
            {
              name: 'AZURE_LOCATION'
              value: location
            }
            {
              name: 'RUNNER_SUBNET_ID'
              value: runnerVirtualNetwork.properties.subnets[0].id
            }
            {
              name: 'RUNNER_VM_SIZE'
              value: runnerVmSize
            }
            {
              name: 'RUNNER_IMAGE_ID'
              value: runnerImageId
            }
            {
              name: 'RUNNER_VM_PRIORITY'
              value: runnerVmPriority
            }
            {
              name: 'RUNNER_PUBLIC_IP'
              value: 'true'
            }
            {
              name: 'RUNNER_ADMIN_USERNAME'
              value: adminUsername
            }
            {
              name: 'RUNNER_ADMIN_SSH_PUBLIC_KEY'
              value: adminSshPublicKey
            }
            {
              name: 'RUNNER_VERSION'
              value: runnerVersion
            }
            {
              name: 'RUNNER_SHA256'
              value: runnerSha256
            }
            {
              name: 'RUNNER_IDLE_TIMEOUT'
              value: '30m'
            }
            {
              name: 'RUNNER_MAX_AGE'
              value: '12h'
            }
            {
              name: 'RECONCILE_INTERVAL'
              value: '1m'
            }
            {
              name: 'PROVISION_CONCURRENCY'
              value: '5'
            }
            {
              name: 'LOG_LEVEL'
              value: 'info'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
  dependsOn: [
    acrPullRoleAssignment
    keyVaultSecretsUserRoleAssignment
    runnerLifecycleRoleAssignment
  ]
}

output containerRegistryName string = containerRegistry.name
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
output githubAppKeyVaultName string = githubAppVault.name
output controllerIdentityClientId string = controllerIdentity.properties.clientId
output controllerName string = deployController ? runnerController!.name : ''
output controllerDeployed bool = deployController
output runnerSubnetId string = runnerVirtualNetwork.properties.subnets[0].id
