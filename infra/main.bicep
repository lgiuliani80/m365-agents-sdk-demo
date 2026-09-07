// Subscription-scope AZD entry point for the weather agent's Azure Container
// Apps + Azure Bot Service infrastructure. See .azure/deployment-plan.md for
// the approved design this file implements.

targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment. Used for resource naming and the resource group name.')
param environmentName string

@minLength(1)
@description('Azure region for all resources.')
param location string

@description('Name of the resource group. Defaults to rg-<environmentName>.')
param resourceGroupName string = 'rg-${environmentName}'

@allowed([
  'managedIdentity'
  'clientSecret'
  'certificate'
])
@description('Selected Azure Bot Service authentication mode.')
param botAuthenticationMode string = 'managedIdentity'

@description('Whether the Azure Bot Service (and its Direct Line channel) is reachable over the public internet.')
param botPublicNetworkAccessEnabled bool = true

@description('Resource group containing the existing Azure OpenAI account.')
param azureOpenAIResourceGroupName string

@description('Name of the existing Azure OpenAI account.')
param azureOpenAIAccountName string

@description('Azure OpenAI endpoint consumed by the agent.')
param azureOpenAIEndpoint string

@description('Azure OpenAI model deployment consumed by the agent.')
param azureOpenAIDeploymentName string

@secure()
@description('Optional OpenWeather API key. When empty, the agent starts but weather tools report a configuration error.')
param openWeatherApiKey string = ''

@secure()
@description('PEM containing the X.509 certificate and matching unencrypted private key. Required only when botAuthenticationMode is "certificate".')
param botCertificatePem string = ''

@description('Base64-encoded public DER certificate extracted locally by the preprovision hook. Required only when botAuthenticationMode is "certificate".')
param botCertificatePublicBase64 string = ''

@description('Certificate thumbprint extracted locally by the preprovision hook. Required only when botAuthenticationMode is "certificate".')
param botCertificateThumbprint string = ''

@description('Initial container image deployed by provisioning. azd deploy overwrites this with the built image.')
param containerImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

var tenantId = subscription().tenantId
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
}
var serviceName = 'agent-framework'

var identityName = 'id-${resourceToken}'
var logAnalyticsName = 'log-${resourceToken}'
var appInsightsName = 'appi-${resourceToken}'
var acrName = 'acr${resourceToken}'
var containerAppsEnvironmentName = 'cae-${resourceToken}'
var containerAppName = 'ca-${resourceToken}'
var botName = 'bot-${resourceToken}'
var graphAppDisplayName = 'app-${environmentName}-bot'

resource rg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  scope: resourceGroup(rg.name)
  params: {
    name: identityName
    location: location
    tags: tags
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: resourceGroup(rg.name)
  params: {
    logAnalyticsName: logAnalyticsName
    appInsightsName: appInsightsName
    location: location
    tags: tags
  }
}

module registry 'modules/registry.bicep' = {
  name: 'registry'
  scope: resourceGroup(rg.name)
  params: {
    name: acrName
    location: location
    tags: tags
    pullPrincipalId: identity.outputs.principalId
  }
}

module azureOpenAIAccess 'modules/azure-openai-access.bicep' = {
  name: 'azureOpenAIAccess'
  scope: resourceGroup(subscription().subscriptionId, azureOpenAIResourceGroupName)
  params: {
    accountName: azureOpenAIAccountName
    principalId: identity.outputs.principalId
  }
}

// Microsoft Graph application/service principal for clientSecret/certificate modes.
// Always deployed (with internal resources conditioned on the mode) so its
// outputs are safely referenceable regardless of the selected mode.
module graphAuth 'modules/graphAuth.bicep' = {
  name: 'graphAuth'
  scope: resourceGroup(rg.name)
  params: {
    displayName: graphAppDisplayName
    botAuthenticationMode: botAuthenticationMode
    certificatePublicBase64: botCertificatePublicBase64
    certificateThumbprintValue: botCertificateThumbprint
  }
}

var botClientId = botAuthenticationMode == 'managedIdentity' ? identity.outputs.clientId : graphAuth.outputs.appId

module containerapps 'modules/containerapps.bicep' = {
  name: 'containerapps'
  scope: resourceGroup(rg.name)
  params: {
    containerAppName: containerAppName
    containerAppsEnvironmentName: containerAppsEnvironmentName
    serviceName: serviceName
    location: location
    tags: tags
    logAnalyticsWorkspaceName: monitoring.outputs.logAnalyticsName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    containerRegistryLoginServer: registry.outputs.loginServer
    userAssignedIdentityId: identity.outputs.id
    userAssignedIdentityClientId: identity.outputs.clientId
    containerImage: containerImage
    tenantId: tenantId
    botAuthenticationMode: botAuthenticationMode
    botClientId: botClientId
    azureOpenAIEndpoint: azureOpenAIEndpoint
    azureOpenAIDeploymentName: azureOpenAIDeploymentName
    openWeatherApiKey: openWeatherApiKey
    certificatePem: botCertificatePem
  }
}

module bot 'modules/bot.bicep' = {
  name: 'bot'
  scope: resourceGroup(rg.name)
  params: {
    name: botName
    displayName: 'Weather Agent (${environmentName})'
    endpoint: 'https://${containerapps.outputs.containerAppFqdn}/api/messages'
    tenantId: tenantId
    botAuthenticationMode: botAuthenticationMode
    msaAppId: botClientId
    msaAppMSIResourceId: identity.outputs.id
    publicNetworkAccessEnabled: botPublicNetworkAccessEnabled
    tags: tags
  }
}

// AZD well-known / conventional outputs (all environment values are written
// to .azure/<env>/.env and are available as process environment variables to
// azd hooks, including scripts/provision-client-secret.ps1).
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenantId
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = registry.outputs.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = registry.outputs.name
output AZURE_CONTAINER_APPS_ENVIRONMENT_ID string = containerapps.outputs.containerAppsEnvironmentId
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = containerapps.outputs.containerAppsEnvironmentName
output AZURE_CONTAINER_APP_NAME string = containerapps.outputs.containerAppName
output AZURE_CONTAINER_APP_FQDN string = containerapps.outputs.containerAppFqdn
output AZURE_USER_ASSIGNED_IDENTITY_ID string = identity.outputs.id
output AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID string = identity.outputs.clientId
output APPLICATIONINSIGHTS_CONNECTION_STRING string = monitoring.outputs.appInsightsConnectionString
output BOT_SERVICE_NAME string = bot.outputs.name
output BOT_AUTHENTICATION_MODE string = botAuthenticationMode
output BOT_CLIENT_ID string = botClientId
output BOT_APP_OBJECT_ID string = graphAuth.outputs.objectId
output BOT_CERTIFICATE_THUMBPRINT string = graphAuth.outputs.certificateThumbprint
output AZURE_OPENAI_ENDPOINT string = azureOpenAIEndpoint
output AZURE_OPENAI_DEPLOYMENT_NAME string = azureOpenAIDeploymentName
output SERVICE_AGENT_FRAMEWORK_ENDPOINT_URL string = 'https://${containerapps.outputs.containerAppFqdn}'
