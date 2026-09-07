// Azure Container Apps managed environment + Container App hosting the agent.
// Configures the user-assigned managed identity for ACR pull, port 8080
// external HTTPS ingress, /health probes, and
// the environment variables required by the .NET configuration system
// (double-underscore section separators) for TokenValidation, the
// Connections:BotServiceConnection settings used by the Agents SDK, and (in
// certificate mode) the BotAuthentication:Certificate:PemPath key read by
// BotCertificateBootstrapper in Program.cs.

@description('Name of the Container App.')
param containerAppName string

@description('Name of the Container Apps managed environment.')
param containerAppsEnvironmentName string

@description('azd service name tag applied to the Container App so azd deploy can locate it.')
param serviceName string

@description('Azure region for the Container Apps resources.')
param location string

@description('Tags applied to the Container Apps resources (azd-service-name is added automatically for the Container App).')
param tags object = {}

@description('Name (in the same resource group) of the Log Analytics workspace used for Container Apps environment logs.')
param logAnalyticsWorkspaceName string

@description('Application Insights connection string.')
param appInsightsConnectionString string

@description('Login server of the Azure Container Registry used to pull the image.')
param containerRegistryLoginServer string

@description('Resource ID of the user-assigned managed identity attached to the Container App.')
param userAssignedIdentityId string

@description('Client ID of the user-assigned managed identity attached to the Container App.')
param userAssignedIdentityClientId string

@description('Initial container image. azd deploy replaces this after the first successful image push.')
param containerImage string

@description('Microsoft Entra tenant ID used for token validation and the bot connection authority.')
param tenantId string

@allowed([
  'managedIdentity'
  'clientSecret'
  'certificate'
])
@description('Selected bot authentication mode.')
param botAuthenticationMode string = 'managedIdentity'

@description('Client (application) ID used for TokenValidation audiences and the bot connection. Either the managed identity client ID or the Microsoft Graph application (appId), depending on botAuthenticationMode.')
param botClientId string

@description('Azure OpenAI endpoint consumed by the agent.')
param azureOpenAIEndpoint string

@description('Azure OpenAI model deployment consumed by the agent.')
param azureOpenAIDeploymentName string

@secure()
@description('Optional OpenWeather API key.')
param openWeatherApiKey string = ''

@secure()
@description('PEM containing the X.509 certificate and matching unencrypted private key. Only used when botAuthenticationMode is "certificate".')
param certificatePem string = ''

// Matches the file paths read by BotCertificateBootstrapper.Configure() in Program.cs:
// BotAuthentication:Certificate:PemPath. The bootstrapper imports the certificate
// into the current user's certificate store and self-populates
// Connections:BotServiceConnection:Settings:CertThumbprint at startup, so no
// thumbprint environment variable is required here.
var certificateVolumeMountPath = '/mnt/secrets/bot-auth'
var certificatePemFileName = 'bot-certificate.pem'

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppsEnvironmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

var baseEnv = [
  {
    name: 'ASPNETCORE_ENVIRONMENT'
    value: 'Production'
  }
  {
    name: 'AZURE_CLIENT_ID'
    value: userAssignedIdentityClientId
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsightsConnectionString
  }
  {
    name: 'Logging__LogLevel__Default'
    value: 'Debug'
  }
  {
    name: 'AIServices__AzureOpenAI__Endpoint'
    value: azureOpenAIEndpoint
  }
  {
    name: 'AIServices__AzureOpenAI__DeploymentName'
    value: azureOpenAIDeploymentName
  }
  {
    name: 'TokenValidation__Audiences__0'
    value: botClientId
  }
  {
    name: 'TokenValidation__TenantId'
    value: tenantId
  }
  {
    name: 'TokenValidation__Enabled'
    value: 'true'
  }
  {
    name: 'Connections__BotServiceConnection__Settings__ClientId'
    value: botClientId
  }
  {
    name: 'Connections__BotServiceConnection__Settings__TenantId'
    value: tenantId
  }
  {
    name: 'Connections__BotServiceConnection__Settings__AuthorityEndpoint'
    value: '${environment().authentication.loginEndpoint}${tenantId}'
  }
  {
    name: 'Connections__BotServiceConnection__Settings__Scopes__0'
    value: 'https://api.botframework.com/.default'
  }
]

var managedIdentityEnv = [
  {
    name: 'Connections__BotServiceConnection__Settings__AuthType'
    value: 'UserManagedIdentity'
  }
]

var clientSecretEnv = [
  {
    name: 'Connections__BotServiceConnection__Settings__AuthType'
    value: 'ClientSecret'
  }
  {
    name: 'Connections__BotServiceConnection__Settings__ClientSecret'
    secretRef: 'bot-client-secret'
  }
]

var certificateEnv = [
  {
    name: 'Connections__BotServiceConnection__Settings__AuthType'
    value: 'Certificate'
  }
  {
    name: 'BotAuthentication__Certificate__PemPath'
    value: '${certificateVolumeMountPath}/${certificatePemFileName}'
  }
]

var modeEnv = botAuthenticationMode == 'managedIdentity' ? managedIdentityEnv : (botAuthenticationMode == 'clientSecret' ? clientSecretEnv : certificateEnv)
var containerEnv = concat(baseEnv, openWeatherEnv, modeEnv)

var clientSecretSecrets = [
  {
    // Placeholder value; replaced by scripts/provision-client-secret.ps1 (azd postprovision hook)
    // immediately after the Graph application password is created. Never set from Bicep.
    name: 'bot-client-secret'
    value: 'placeholder-set-by-postprovision-hook'
  }
]

var openWeatherEnv = !empty(openWeatherApiKey) ? [
  {
    name: 'OpenWeatherApiKey'
    secretRef: 'openweather-api-key'
  }
] : []

var applicationSecrets = !empty(openWeatherApiKey) ? [
  {
    name: 'openweather-api-key'
    value: openWeatherApiKey
  }
] : []

var certificateSecrets = [
  {
    name: 'bot-certificate-pem'
    value: certificatePem
  }
]

var modeSecrets = botAuthenticationMode == 'clientSecret' ? clientSecretSecrets : (botAuthenticationMode == 'certificate' ? certificateSecrets : [])
var containerSecrets = concat(applicationSecrets, modeSecrets)

var certificateVolumes = [
  {
    name: 'bot-certificate'
    storageType: 'Secret'
    secrets: [
      {
        secretRef: 'bot-certificate-pem'
        path: certificatePemFileName
      }
    ]
  }
]

var containerVolumes = botAuthenticationMode == 'certificate' ? certificateVolumes : []

var certificateVolumeMounts = [
  {
    volumeName: 'bot-certificate'
    mountPath: certificateVolumeMountPath
  }
]

var containerVolumeMounts = botAuthenticationMode == 'certificate' ? certificateVolumeMounts : []

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  tags: union(tags, {
    'azd-service-name': serviceName
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    environmentId: containerAppsEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: containerRegistryLoginServer
          identity: userAssignedIdentityId
        }
      ]
      secrets: containerSecrets
    }
    template: {
      containers: [
        {
          name: serviceName
          image: containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: containerEnv
          volumeMounts: containerVolumeMounts
          probes: [
            {
              type: 'Startup'
              httpGet: {
                path: '/health'
                port: 8080
              }
              initialDelaySeconds: 3
              periodSeconds: 5
              timeoutSeconds: 3
              failureThreshold: 20
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health'
                port: 8080
              }
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: 3
            }
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: 8080
              }
              initialDelaySeconds: 5
              periodSeconds: 15
              timeoutSeconds: 5
              failureThreshold: 3
            }
          ]
        }
      ]
      volumes: containerVolumes
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

output containerAppsEnvironmentId string = containerAppsEnvironment.id
output containerAppsEnvironmentName string = containerAppsEnvironment.name
output containerAppId string = containerApp.id
output containerAppName string = containerApp.name
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
