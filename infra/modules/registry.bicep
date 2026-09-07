// Azure Container Registry (Basic SKU) with AcrPull granted to the Container App's
// user-assigned managed identity so the Container App can pull images without
// admin credentials.

@description('Name of the container registry. Must be globally unique, lowercase alphanumeric.')
param name string

@description('Azure region for the registry.')
param location string

@description('Tags applied to the registry.')
param tags object = {}

@description('Principal ID (object ID) of the identity that should be granted AcrPull.')
param pullPrincipalId string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
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

// AcrPull built-in role definition ID: 7f951dda-4ed3-4680-a7ca-43fe172d538d
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, pullPrincipalId, 'AcrPull')
  scope: acr
  properties: {
    principalId: pullPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

output id string = acr.id
output name string = acr.name
output loginServer string = acr.properties.loginServer
