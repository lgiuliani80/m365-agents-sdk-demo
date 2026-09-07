#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Prepares public certificate metadata before AZD provisions Azure resources.

.DESCRIPTION
    In certificate authentication mode, validates that BOT_CERTIFICATE_PEM
    contains an X.509 certificate and its matching unencrypted private key.
    It stores only the public DER certificate and thumbprint as derived AZD
    environment values consumed by Bicep. The PEM and private key are never
    written to output or copied to another local file.
#>

#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Info {
    param([string]$Message)
    Write-Host "prepare-certificate: $Message"
}

$authMode = $env:BOT_AUTHENTICATION_MODE
if ([string]::IsNullOrWhiteSpace($authMode) -or $authMode -ne 'certificate') {
    Write-Info "botAuthenticationMode is '$authMode' (not 'certificate'); nothing to do."
    exit 0
}

$certificatePem = $env:BOT_CERTIFICATE_PEM
if ([string]::IsNullOrWhiteSpace($certificatePem)) {
    throw 'prepare-certificate: BOT_CERTIFICATE_PEM is required when BOT_AUTHENTICATION_MODE is certificate.'
}

$certificate = $null
try {
    try {
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
            $certificatePem,
            $certificatePem)
    }
    catch {
        throw 'prepare-certificate: BOT_CERTIFICATE_PEM must contain an X.509 certificate and its matching unencrypted private key.'
    }

    if (-not $certificate.HasPrivateKey) {
        throw 'prepare-certificate: BOT_CERTIFICATE_PEM does not contain a matching private key.'
    }

    $publicCertificateBase64 = [Convert]::ToBase64String($certificate.RawData)
    $thumbprint = $certificate.Thumbprint

    Write-Info 'saving derived public certificate metadata in the selected AZD environment.'
    azd env set BOT_CERTIFICATE_PUBLIC_BASE64 $publicCertificateBase64 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'prepare-certificate: failed to set BOT_CERTIFICATE_PUBLIC_BASE64 in the AZD environment.'
    }

    azd env set BOT_CERTIFICATE_THUMBPRINT $thumbprint | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'prepare-certificate: failed to set BOT_CERTIFICATE_THUMBPRINT in the AZD environment.'
    }

    Write-Info "certificate metadata prepared (thumbprint: $thumbprint)."
}
finally {
    if ($null -ne $certificate) {
        $certificate.Dispose()
    }

    $certificatePem = $null
    Remove-Variable -Name certificatePem -ErrorAction SilentlyContinue
}
