#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Idempotent azd postprovision hook for the "clientSecret" bot authentication mode.

.DESCRIPTION
    Azure Bot Service in "clientSecret" mode uses a Microsoft Entra application
    (created by infra/modules/graphAuth.bicep) authenticated with an
    application password. The Microsoft Graph Bicep extension does not support
    the applications/{id}/addPassword action, so this script performs that
    step outside of Bicep, after infra/main.bicep has provisioned the
    application object, the Key Vault, and the Container App.

    The script is safe to run on every `azd provision`:
      - It no-ops immediately unless BOT_AUTHENTICATION_MODE is "clientSecret".
      - It only requests a new Microsoft Graph application password the first
        time it runs (detected by checking whether the Key Vault secret already
        holds a real value rather than the Bicep-provisioned placeholder).
      - The secret value is written directly to Key Vault and to the Container
        App's own secret store, but is never written to stdout, azd outputs, or
        any log file.

.NOTES
    Requires: Azure CLI (az), signed in with an account/service principal that
    has Microsoft Graph "Application.ReadWrite.All" (to add the password) and
    Key Vault "Key Vault Secrets Officer" plus Container Apps "Contributor" on
    the target resource group (both are granted by infra/main.bicep to the
    azd principal via the `principalId` parameter).
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

$requiredEnvVars = @('BOT_APP_OBJECT_ID', 'AZURE_KEY_VAULT_NAME', 'AZURE_RESOURCE_GROUP', 'AZURE_CONTAINER_APP_NAME')
foreach ($name in $requiredEnvVars) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "provision-client-secret: required environment variable '$name' is not set. Run 'azd provision' so infra/main.bicep outputs are exported to this environment before this hook runs."
    }
}

$appObjectId = $env:BOT_APP_OBJECT_ID
$vaultName = $env:AZURE_KEY_VAULT_NAME
$resourceGroup = $env:AZURE_RESOURCE_GROUP
$containerAppName = $env:AZURE_CONTAINER_APP_NAME

az account show --output none
if ($LASTEXITCODE -ne 0) {
    throw 'provision-client-secret: not signed in to Azure CLI (az login) - cannot proceed.'
}

Write-Info "checking whether Key Vault secret '$secretName' in vault '$vaultName' already holds a provisioned value."

$existingSecretValue = az keyvault secret show --vault-name $vaultName --name $secretName --query 'value' --output tsv 2>$null
$hasRealSecret = (-not [string]::IsNullOrWhiteSpace($existingSecretValue)) -and ($existingSecretValue -ne 'placeholder-set-by-postprovision-hook')
$existingSecretValue = $null

if ($hasRealSecret) {
    Write-Info 'a client secret is already provisioned; skipping Microsoft Graph password creation (idempotent no-op).'
}
else {
    Write-Info "no client secret provisioned yet; requesting a new application password from Microsoft Graph for application object $appObjectId."

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
    $secretValue = $response.secretText
    $responseJson = $null
    $response = $null

    if ([string]::IsNullOrWhiteSpace($secretValue)) {
        throw 'provision-client-secret: Microsoft Graph did not return a secretText value.'
    }

    try {
        Write-Info 'storing the new application password in Key Vault (value is not logged).'
        az keyvault secret set --vault-name $vaultName --name $secretName --value $secretValue --output none | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "provision-client-secret: failed to store the secret in Key Vault '$vaultName'."
        }

        Write-Info 'updating the Container App secret (value is not logged).'
        az containerapp secret set --name $containerAppName --resource-group $resourceGroup --secrets "$secretName=$secretValue" --output none | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "provision-client-secret: failed to update the Container App secret on '$containerAppName'."
        }
    }
    finally {
        $secretValue = $null
        Remove-Variable -Name secretValue -ErrorAction SilentlyContinue
    }

    $hasRealSecret = $true
}

if ($hasRealSecret) {
    Write-Info 'restarting the active Container App revision so the current secret value is loaded.'
    $latestRevision = az containerapp revision list --name $containerAppName --resource-group $resourceGroup --query "[?properties.active] | [0].name" --output tsv
    if (-not [string]::IsNullOrWhiteSpace($latestRevision)) {
        az containerapp revision restart --name $containerAppName --resource-group $resourceGroup --revision $latestRevision --output none | Out-Null
    }
    else {
        Write-Info 'no active revision found yet; the Container App will read the secret on its next revision.'
    }
}

Write-Info 'done.'
