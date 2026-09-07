$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$environmentName = $env:AZURE_ENV_NAME

if ([string]::IsNullOrWhiteSpace($environmentName)) {
    throw 'AZURE_ENV_NAME is not set. Run the script through an azd hook or select an azd environment.'
}

$agentConfigPath = Join-Path $projectRoot 'a365.generated.config.json'
$manifestPath = Join-Path $projectRoot 'appPackage\manifest.json'
$colorIconPath = Join-Path $projectRoot 'appPackage\color.png'
$outlineIconPath = Join-Path $projectRoot 'appPackage\outline.png'

foreach ($requiredFile in @($agentConfigPath, $manifestPath, $colorIconPath, $outlineIconPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required file not found: $requiredFile"
    }
}

$agentConfig = Get-Content -LiteralPath $agentConfigPath -Raw | ConvertFrom-Json
$botId = $agentConfig.agenticAppId
$parsedBotId = [guid]::Empty

if ([string]::IsNullOrWhiteSpace($botId) -or -not [guid]::TryParse($botId, [ref]$parsedBotId)) {
    throw "The agenticAppId in '$agentConfigPath' is missing or is not a valid GUID."
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$manifest.id = $botId

if (-not $manifest.bots -or $manifest.bots.Count -eq 0) {
    throw "The Teams manifest '$manifestPath' does not define any bots."
}

foreach ($bot in $manifest.bots) {
    $bot.botId = $botId
}

$appNameSuffixToken = '${{APP_NAME_SUFFIX}}'
if (-not $manifest.name.short.Contains($appNameSuffixToken)) {
    throw "The Teams manifest short name does not contain the $appNameSuffixToken placeholder."
}

$manifest.name.short = $manifest.name.short.Replace($appNameSuffixToken, "-$environmentName")

$environmentDirectory = Join-Path $projectRoot (Join-Path '.azure' $environmentName)
New-Item -ItemType Directory -Path $environmentDirectory -Force | Out-Null

$safeEnvironmentName = $environmentName -replace '[^A-Za-z0-9._-]', '-'
$zipName = "teams-app-$safeEnvironmentName.zip"
$zipPath = Join-Path $environmentDirectory $zipName
$stagingDirectory = Join-Path $environmentDirectory ".teams-app-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $stagingDirectory | Out-Null

    $generatedManifestPath = Join-Path $stagingDirectory 'manifest.json'
    $manifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $generatedManifestPath -Encoding utf8NoBOM
    Copy-Item -LiteralPath $colorIconPath, $outlineIconPath -Destination $stagingDirectory

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    Compress-Archive -Path (Join-Path $stagingDirectory '*') -DestinationPath $zipPath
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
}

Write-Host "Teams app package: $zipName"
Write-Host "Path: $zipPath"

$azureServiceEndpointUrl = [Environment]::GetEnvironmentVariable('SERVICE_AGENT_FRAMEWORK_ENDPOINT_URL')
$azureAgentEndpoint = if ([string]::IsNullOrWhiteSpace($azureServiceEndpointUrl)) {
    '<AZURE_AGENT_URL>/api/messages'
}
else {
    "$($azureServiceEndpointUrl.TrimEnd('/'))/api/messages"
}

Write-Host ''
Write-Host 'Microsoft 365 Agents Playground'
Write-Host '================================'
Write-Host ''
Write-Host 'Install:'
Write-Host '  npm install -g @microsoft/m365agentsplayground'
Write-Host ''
Write-Host 'Run the agent locally (from the project root):'
Write-Host '  dotnet run --launch-profile AgentFrameworkWeather'
Write-Host ''
Write-Host 'In another terminal, connect Agents Playground to the local agent:'
Write-Host '  agentsplayground --app-endpoint "http://localhost:3978/api/messages" --channel-id msteams'
Write-Host ''
Write-Host 'Connect Agents Playground to the agent running in Azure:'
Write-Host '1. Start Agents Playground on its default port and expose it through ngrok:'
Write-Host '  ngrok http 56150'
Write-Host ''
Write-Host '2. Copy the HTTPS forwarding URL printed by ngrok, then run:'
Write-Host '  $ngrokUrl = "https://<NGROK_HTTPS_URL>"'
Write-Host '  $agentConfig = Get-Content .\a365.generated.config.json -Raw | ConvertFrom-Json'
Write-Host '  $tenantId = az account show --query tenantId --output tsv'
Write-Host "  agentsplayground --app-endpoint `"$azureAgentEndpoint`" --channel-id msteams --service-url `"`$ngrokUrl/_connector`" --client-id `$agentConfig.agenticAppId --client-secret `$agentConfig.agentBlueprintClientSecret --tenant-id `$tenantId"
Write-Host ''
Write-Host 'NOTES:'
Write-Host '  - Options --client-id, --client-secret, and --tenant-id can be omitted if TokenValidation__Enabled is set to false.'
Write-Host '  - make sure to replace <NGROK_HTTPS_URL> with the actual HTTPS forwarding URL from ngrok.'
