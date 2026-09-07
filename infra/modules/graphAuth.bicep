// Microsoft Graph single-tenant application + service principal used for the
// Azure Bot Service registration when botAuthenticationMode is "clientSecret"
// or "certificate". No Graph resources are created for "managedIdentity" mode.
//
// For "certificate" mode, a deployment script (running as the supplied
// user-assigned identity) extracts ONLY the public certificate (base64 DER)
// and its thumbprint/validity from the secure PFX/password parameters, using
// the official deployment-script pattern documented by the Microsoft Graph
// Bicep quickstart templates. The private key is never persisted, output, or
// logged - it only ever lives in the deployment script container's memory
// for the duration of the extraction.
//
// Client secret creation is intentionally NOT done here: the Microsoft Graph
// Bicep extension does not support the applications/{id}/addPassword action,
// so that step is performed idempotently by the azd postprovision hook
// (scripts/provision-client-secret.ps1) after this module has created the
// application object.

extension microsoftGraphV1

@description('Display name for the Entra application registration.')
param displayName string

@allowed([
  'managedIdentity'
  'clientSecret'
  'certificate'
])
@description('Selected bot authentication mode.')
param botAuthenticationMode string = 'managedIdentity'

@secure()
@description('Base64-encoded PFX certificate contents. Only used in "certificate" mode.')
param certificatePfxBase64 string = ''

@secure()
@description('Password protecting the PFX certificate. Only used in "certificate" mode.')
param certificatePfxPassword string = ''

@description('Resource ID of the user-assigned managed identity used to run the certificate extraction deployment script.')
param scriptIdentityId string = ''

@description('Azure region for the certificate extraction deployment script.')
param location string

@description('Forces the deployment script to re-run on every deployment.')
param utcValue string = utcNow()

var isSingleTenantMode = botAuthenticationMode == 'clientSecret' || botAuthenticationMode == 'certificate'
var isCertificateMode = botAuthenticationMode == 'certificate'

resource extractCertificate 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (isCertificateMode) {
  name: 'extract-bot-certificate'
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scriptIdentityId}': {}
    }
  }
  properties: {
    azPowerShellVersion: '11.0'
    retentionInterval: 'PT1H'
    cleanupPreference: 'OnSuccess'
    forceUpdateTag: utcValue
    timeout: 'PT10M'
    environmentVariables: [
      {
        name: 'PFX_BASE64'
        secureValue: certificatePfxBase64
      }
      {
        name: 'PFX_PASSWORD'
        secureValue: certificatePfxPassword
      }
    ]
    scriptContent: '''
      $ErrorActionPreference = "Stop"
      $pfxBytes = [Convert]::FromBase64String($env:PFX_BASE64)
      $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
        $pfxBytes,
        $env:PFX_PASSWORD,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
      )
      $publicKeyBase64 = [Convert]::ToBase64String($cert.GetRawCertData())
      $DeploymentScriptOutputs = @{}
      $DeploymentScriptOutputs["publicCertificateBase64"] = $publicKeyBase64
      $DeploymentScriptOutputs["thumbprint"] = $cert.Thumbprint
      $DeploymentScriptOutputs["notBefore"] = $cert.NotBefore.ToUniversalTime().ToString("o")
      $DeploymentScriptOutputs["notAfter"] = $cert.NotAfter.ToUniversalTime().ToString("o")
      # Never write certificate bytes, password, or private key material to the script log.
      Write-Host "Extracted public certificate metadata (thumbprint: $($cert.Thumbprint))."
    '''
  }
}

resource graphApp 'Microsoft.Graph/applications@v1.0' = if (isSingleTenantMode) {
  uniqueName: toLower(replace(displayName, ' ', '-'))
  displayName: displayName
  signInAudience: 'AzureADMyOrg'
  keyCredentials: isCertificateMode ? [
    {
      displayName: 'Bot Service certificate credential'
      usage: 'Verify'
      type: 'AsymmetricX509Cert'
      key: extractCertificate!.properties.outputs.publicCertificateBase64
    }
  ] : []
}

resource graphSp 'Microsoft.Graph/servicePrincipals@v1.0' = if (isSingleTenantMode) {
  appId: graphApp!.appId
}

output appId string = isSingleTenantMode ? graphApp!.appId : ''
output objectId string = isSingleTenantMode ? graphApp!.id : ''
output servicePrincipalId string = isSingleTenantMode ? graphSp!.id : ''
output certificateThumbprint string = isCertificateMode ? extractCertificate!.properties.outputs.thumbprint : ''
output certificateNotAfter string = isCertificateMode ? extractCertificate!.properties.outputs.notAfter : ''
