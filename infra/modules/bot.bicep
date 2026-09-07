// Azure Bot Service (F0, global) with a Direct Line channel. Supports the
// three authentication modes described in the deployment plan: for
// "managedIdentity" the bot uses the user-assigned managed identity directly
// (msaAppType UserAssignedMSI, no Entra App Registration); for
// "clientSecret"/"certificate" the bot uses the Microsoft Graph application
// created in modules/graphAuth.bicep (msaAppType SingleTenant).

@description('Name of the Azure Bot Service resource.')
param name string

@description('Display name shown for the bot.')
param displayName string

@description('Messaging endpoint the bot service will call (Container App FQDN + /api/messages).')
param endpoint string

@description('Microsoft Entra tenant ID.')
param tenantId string

@allowed([
  'managedIdentity'
  'clientSecret'
  'certificate'
])
@description('Selected bot authentication mode.')
param botAuthenticationMode string = 'managedIdentity'

@description('Microsoft App ID (client ID) for the bot: the user-assigned identity client ID for managedIdentity mode, or the Microsoft Graph application appId otherwise.')
param msaAppId string

@description('Resource ID of the user-assigned managed identity. Required for managedIdentity mode.')
param msaAppMSIResourceId string = ''

@description('Whether the Bot Service public network access (and therefore the Direct Line public endpoint) is enabled.')
param publicNetworkAccessEnabled bool = true

@description('Tags applied to the Bot Service resource.')
param tags object = {}

resource bot 'Microsoft.BotService/botServices@2023-09-15-preview' = {
  name: name
  location: 'global'
  tags: tags
  sku: {
    name: 'F0'
  }
  kind: 'azurebot'
  properties: {
    displayName: displayName
    endpoint: endpoint
    msaAppId: msaAppId
    msaAppType: botAuthenticationMode == 'managedIdentity' ? 'UserAssignedMSI' : 'SingleTenant'
    msaAppTenantId: tenantId
    msaAppMSIResourceId: botAuthenticationMode == 'managedIdentity' ? msaAppMSIResourceId : null
    publicNetworkAccess: publicNetworkAccessEnabled ? 'Enabled' : 'Disabled'
    isStreamingSupported: false
  }
}

resource directLineChannel 'Microsoft.BotService/botServices/channels@2023-09-15-preview' = {
  parent: bot
  name: 'DirectLineChannel'
  location: 'global'
  properties: {
    channelName: 'DirectLineChannel'
    properties: {
      sites: [
        {
          siteName: 'default'
          isEnabled: true
          isV1Enabled: false
          isV3Enabled: true
          isSecureSiteEnabled: false
          isBlockUserUploadEnabled: false
        }
      ]
    }
  }
}

output id string = bot.id
output name string = bot.name
