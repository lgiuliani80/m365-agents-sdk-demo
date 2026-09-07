#!/usr/bin/env pwsh
<#
.SYNOPSIS
    azd postprovision hook for the "clientSecret" bot authentication mode.

.DESCRIPTION
    Azure Bot Service in "clientSecret" mode uses a Microsoft Entra application
    (created by infra/modules/graphAuth.bicep) authenticated with an
    application password. The Microsoft Graph Bicep extension does not support
    the applications/{id}/addPassword action, so this script performs that
    step outside of Bicep, after infra/main.bicep has provisioned the
    application object and the Container App.

    The script is safe to run on every `azd provision`:
            - It no-ops immediately unless BOT_AUTHENTICATION_MODE is "clientSecret".
            - It creates a new Microsoft Graph application password and writes it
                directly to the Container App's secret store without logging it.
            - It restarts the active revision before removing older credentials
                created by this hook, avoiding an authentication outage during rotation.

.NOTES
    Requires: Azure CLI (az), signed in with an account/service principal that
    has Microsoft Graph "Application.ReadWrite.All" and Container Apps
    "Contributor" on the target resource group.
#>

#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$secretName = 'bot-client-secret'
$credentialDisplayName = 'azd-provisioned-client-secret'

function Write-Info {
    param([string]$Message)
    Write-Host "provision-client-secret: $Message"
}

$authMode = $env:BOT_AUTHENTICATION_MODE
if ([string]::IsNullOrWhiteSpace($authMode) -or $authMode -ne 'clientSecret') {
    Write-Info "botAuthenticationMode is '$authMode' (not 'clientSecret'); nothing to do."
    exit 0
}

$requiredEnvVars = @('BOT_APP_OBJECT_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_CONTAINER_APP_NAME')
foreach ($name in $requiredEnvVars) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "provision-client-secret: required environment variable '$name' is not set. Run 'azd provision' so infra/main.bicep outputs are exported to this environment before this hook runs."
    }
}

$appObjectId = $env:BOT_APP_OBJECT_ID
$resourceGroup = $env:AZURE_RESOURCE_GROUP
$containerAppName = $env:AZURE_CONTAINER_APP_NAME

az account show --output none
if ($LASTEXITCODE -ne 0) {
    throw 'provision-client-secret: not signed in to Azure CLI (az login) - cannot proceed.'
}

Write-Info "reading existing application-password metadata for application object $appObjectId."
$applicationJson = az rest `
    --method GET `
    --uri "https://graph.microsoft.com/v1.0/applications/${appObjectId}?%24select=passwordCredentials" `
    --output json
if ($LASTEXITCODE -ne 0) {
    throw 'provision-client-secret: failed to read existing Microsoft Graph application passwords.'
}

$application = $applicationJson | ConvertFrom-Json
$oldCredentialIds = @(
    $application.passwordCredentials |
        Where-Object { $_.displayName -eq $credentialDisplayName } |
        ForEach-Object { $_.keyId }
)
$applicationJson = $null
$application = $null

Write-Info "requesting a new application password from Microsoft Graph for application object $appObjectId."
$addPasswordBody = @{
    passwordCredential = @{
        displayName = $credentialDisplayName
    }
} | ConvertTo-Json -Compress -Depth 5

$bodyFile = New-TemporaryFile
try {
    Set-Content -Path $bodyFile -Value $addPasswordBody -NoNewline -Encoding utf8
    $responseJson = az rest `
        --method POST `
        --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId/addPassword" `
        --headers 'Content-Type=application/json' `
        --body "@$bodyFile" `
        --output json
    if ($LASTEXITCODE -ne 0) {
        throw 'provision-client-secret: Microsoft Graph addPassword request failed. Ensure the signed-in principal has Application.ReadWrite.All.'
    }
}
finally {
    Remove-Item -Path $bodyFile -ErrorAction SilentlyContinue
}

$response = $responseJson | ConvertFrom-Json
$newCredentialId = $response.keyId
$secretValue = $response.secretText
$responseJson = $null
$response = $null

if ([string]::IsNullOrWhiteSpace($newCredentialId) -or [string]::IsNullOrWhiteSpace($secretValue)) {
    throw 'provision-client-secret: Microsoft Graph did not return the new keyId and secretText values.'
}

try {
    Write-Info 'updating the Container App secret (value is not logged).'
    az containerapp secret set --name $containerAppName --resource-group $resourceGroup --secrets "$secretName=$secretValue" --output none | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "provision-client-secret: failed to update the Container App secret on '$containerAppName'."
    }
}
catch {
    Write-Info 'Container App update failed; removing the newly created unusable application password.'
    $removePasswordBody = @{ keyId = $newCredentialId } | ConvertTo-Json -Compress
    $removeBodyFile = New-TemporaryFile
    try {
        Set-Content -Path $removeBodyFile -Value $removePasswordBody -NoNewline -Encoding utf8
        az rest --method POST --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId/removePassword" --headers 'Content-Type=application/json' --body "@$removeBodyFile" --output none | Out-Null
    }
    finally {
        Remove-Item -Path $removeBodyFile -ErrorAction SilentlyContinue
    }
    throw
}
finally {
    $secretValue = $null
    Remove-Variable -Name secretValue -ErrorAction SilentlyContinue
}

Write-Info 'restarting the active Container App revision so the new secret value is loaded.'
$latestRevision = az containerapp revision list --name $containerAppName --resource-group $resourceGroup --query "[?properties.active] | [0].name" --output tsv
if (-not [string]::IsNullOrWhiteSpace($latestRevision)) {
    az containerapp revision restart --name $containerAppName --resource-group $resourceGroup --revision $latestRevision --output none | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'provision-client-secret: failed to restart the active Container App revision; older application passwords were preserved.'
    }
}
else {
    Write-Info 'no active revision found yet; the Container App will read the secret on its next revision.'
}

foreach ($credentialId in $oldCredentialIds) {
    Write-Info "removing superseded application password $credentialId."
    $removePasswordBody = @{ keyId = $credentialId } | ConvertTo-Json -Compress
    $removeBodyFile = New-TemporaryFile
    try {
        Set-Content -Path $removeBodyFile -Value $removePasswordBody -NoNewline -Encoding utf8
        az rest --method POST --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId/removePassword" --headers 'Content-Type=application/json' --body "@$removeBodyFile" --output none | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "provision-client-secret: failed to remove superseded application password '$credentialId'."
        }
    }
    finally {
        Remove-Item -Path $removeBodyFile -ErrorAction SilentlyContinue
    }
}

Write-Info 'done.'
