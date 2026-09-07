// Key Vault with RBAC authorization, soft delete, and purge protection enabled.
// In "certificate" bot authentication mode, the supplied PFX/password secure
// parameters are stored here as secrets (never emitted as deployment outputs).
// The Container App's managed identity is granted Key Vault Secrets User so it
// can resolve keyVaultUrl-backed Container App secrets/volumes at runtime. The
// deploying principal (azd's AZURE_PRINCIPAL_ID) is granted Key Vault Secrets
// Officer so azd provision and the postprovision hook can manage secrets.

@description('Name of the Key Vault. Must be globally unique.')
param name string

@description('Azure region for the Key Vault.')
param location string

@description('Tags applied to the Key Vault.')
param tags object = {}

@description('Tenant ID for the Key Vault.')
param tenantId string

@description('Principal ID (object ID) of the Container App managed identity. Granted Key Vault Secrets User.')
param containerAppPrincipalId string

@description('Principal ID (object ID) of the deploying identity (azd principalId). Granted Key Vault Secrets Officer when non-empty.')
param deployerPrincipalId string = ''

@allowed([
  'managedIdentity'
  'clientSecret'
  'certificate'
])
@description('Selected bot authentication mode. Only "certificate" mode provisions PFX/password secrets here.')
param botAuthenticationMode string = 'managedIdentity'

@secure()
@description('Base64-encoded PFX certificate contents. Only used in "certificate" mode.')
param certificatePfxBase64 string = ''

@secure()
@description('Password protecting the PFX certificate. Only used in "certificate" mode.')
param certificatePfxPassword string = ''

var isCertificateMode = botAuthenticationMode == 'certificate'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource pfxSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (isCertificateMode) {
  parent: keyVault
  name: 'bot-certificate-pfx'
  properties: {
    value: certificatePfxBase64
    contentType: 'application/x-pkcs12;base64'
  }
}

resource passwordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (isCertificateMode) {
  parent: keyVault
  name: 'bot-certificate-password'
  properties: {
    value: certificatePfxPassword
    contentType: 'text/plain'
  }
}

// Key Vault Secrets User built-in role definition ID: 4633458b-17de-408a-b874-0445c86b69e6
resource containerAppSecretsUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, containerAppPrincipalId, 'KeyVaultSecretsUser')
  scope: keyVault
  properties: {
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}

// Key Vault Secrets Officer built-in role definition ID: b86a8fe4-44ce-4948-aee5-eccb2c155cd7
resource deployerSecretsOfficerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  name: guid(keyVault.id, deployerPrincipalId, 'KeyVaultSecretsOfficer')
  scope: keyVault
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  }
}

output id string = keyVault.id
output name string = keyVault.name
output uri string = keyVault.properties.vaultUri
output pfxSecretUri string = isCertificateMode ? pfxSecret!.properties.secretUri : ''
#disable-next-line outputs-should-not-contain-secrets
output passwordSecretUri string = isCertificateMode ? passwordSecret!.properties.secretUri : ''
