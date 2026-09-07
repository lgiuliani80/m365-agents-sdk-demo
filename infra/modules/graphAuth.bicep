// Microsoft Graph single-tenant application + service principal used for the
// Azure Bot Service registration when botAuthenticationMode is "clientSecret"
// or "certificate". No Graph resources are created for "managedIdentity" mode.
//
// For "certificate" mode, the local AZD preprovision hook validates the PEM
// and supplies only the public certificate (base64 DER) and its thumbprint.
// This module never receives the private key.
//
// Client secret creation is intentionally NOT done here: the Microsoft Graph
// Bicep extension does not support the applications/{id}/addPassword action,
// so that step is performed by the azd postprovision hook
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

@description('Base64-encoded public DER certificate extracted by the local preprovision hook. Only used in "certificate" mode.')
param certificatePublicBase64 string = ''

@description('Certificate thumbprint extracted by the local preprovision hook. Only used in "certificate" mode.')
param certificateThumbprintValue string = ''

var isSingleTenantMode = botAuthenticationMode == 'clientSecret' || botAuthenticationMode == 'certificate'
var isCertificateMode = botAuthenticationMode == 'certificate'

resource graphApp 'Microsoft.Graph/applications@v1.0' = if (isSingleTenantMode) {
  uniqueName: toLower(replace(displayName, ' ', '-'))
  displayName: displayName
  signInAudience: 'AzureADMyOrg'
  keyCredentials: isCertificateMode ? [
    {
      displayName: 'Bot Service certificate credential'
      usage: 'Verify'
      type: 'AsymmetricX509Cert'
      key: certificatePublicBase64
    }
  ] : []
}

resource graphSp 'Microsoft.Graph/servicePrincipals@v1.0' = if (isSingleTenantMode) {
  appId: graphApp!.appId
}

output appId string = isSingleTenantMode ? graphApp!.appId : ''
output objectId string = isSingleTenantMode ? graphApp!.id : ''
output servicePrincipalId string = isSingleTenantMode ? graphSp!.id : ''
output certificateThumbprint string = isCertificateMode ? certificateThumbprintValue : ''
