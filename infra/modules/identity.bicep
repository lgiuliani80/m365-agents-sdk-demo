// User-assigned managed identity used by the Container App for ACR pull and,
// in managedIdentity bot auth mode, as the Azure Bot Service application
// identity.

@description('Name of the user-assigned managed identity.')
param name string

@description('Azure region for the identity.')
param location string

@description('Tags applied to the identity.')
param tags object = {}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

output id string = identity.id
output name string = identity.name
output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
