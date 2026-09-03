// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using AgentFrameworkWeather;
using AgentFrameworkWeather.Agent;
using Azure;
using Azure.Identity;
using Azure.AI.OpenAI;
using Microsoft.Agents.A365.Observability.Extensions.AgentFramework;
using Microsoft.Agents.A365.Observability.Hosting.Middleware;
using Microsoft.Agents.A365.Observability.Runtime;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core;
using Microsoft.Agents.Hosting.AspNetCore;
using Microsoft.Agents.Storage;
using Microsoft.Agents.Storage.Transcript;
using Microsoft.Extensions.AI;
using System.Diagnostics;
using System.Reflection;

var builder = WebApplication.CreateBuilder(args);

builder.Configuration.AddUserSecrets(Assembly.GetExecutingAssembly());
builder.Services.AddControllers();
builder.Services.AddHttpClient("WebClient", client => client.Timeout = TimeSpan.FromSeconds(600));
builder.Services.AddHttpContextAccessor();

// Configure defaults for Aspire dashboard
builder.ConfigureOtelProviders();
//TODO builder.AddA365Tracing(configure: config => config.WithAgentFramework());

builder.Logging.AddConsole();

// Register IStorage.  For development, MemoryStorage is suitable.
// For production Agents, persisted storage should be used so
// that state survives Agent restarts, and operate correctly
// in a cluster of Agent instances.
builder.Services.AddSingleton<IStorage, MemoryStorage>();

// Add the bot (which is transient) and configure AspNet token validation.
// Authorization (and therefore required auth on the mapped endpoints) is enabled
// for all environments except Development and Playground.
builder.AddAgentDefaults()
    .AddAgent<WeatherAgent>()
    .AddAgentAuthorization(
        b => b.AddAgentAspNetAuthentication(),
        forceEnable: !(builder.Environment.IsDevelopment() || builder.Environment.EnvironmentName == "Playground"));

// Register IChatClient with correct types
builder.Services.AddSingleton<IChatClient>(sp =>
{

    var confSvc = sp.GetRequiredService<IConfiguration>();
    var endpoint = confSvc["AIServices:AzureOpenAI:Endpoint"] ?? string.Empty;
    var deployment = confSvc["AIServices:AzureOpenAI:DeploymentName"] ?? string.Empty;

    // Validate OpenWeatherAPI key. 
    var openWeatherApiKey = confSvc["OpenWeatherApiKey"] ?? string.Empty;

    AssertionHelpers.ThrowIfNullOrEmpty(endpoint, "AIServices:AzureOpenAI:Endpoint configuration is missing and required.");
    AssertionHelpers.ThrowIfNullOrEmpty(deployment, "AIServices:AzureOpenAI:DeploymentName configuration is missing and required.");
    AssertionHelpers.ThrowIfNullOrEmpty(openWeatherApiKey, "OpenWeatherApiKey configuration is missing and required.");

    // Convert endpoint to Uri
    var endpointUri = new Uri(endpoint);

    var credential = new DefaultAzureCredential();

    // Create and return the AzureOpenAIClient's ChatClient
    return new AzureOpenAIClient(endpointUri, credential).GetChatClient(deployment).AsIChatClient();
});

// Add Agent 365 baggage to every turn and log conversations to transcript files.
builder.Services.AddSingleton<Microsoft.Agents.Builder.IMiddleware[]>(
[
    //TODO new BaggageTurnMiddleware(),
    new TranscriptLoggerMiddleware(new FileTranscriptLogger())
]);

var app = builder.Build();

// Log inbound requests before authentication runs. Never write bearer tokens to logs.
app.Use(async (context, next) =>
{
    var logger = context.RequestServices
        .GetRequiredService<ILoggerFactory>()
        .CreateLogger("RequestLogging");
    var authorization = context.Request.Headers.Authorization.ToString();
    var stopwatch = Stopwatch.StartNew();

    logger.LogDebug(
        "HTTP request {Method} {Path}{QueryString}; Authorization={Authorization}; TraceIdentifier={TraceIdentifier}",
        context.Request.Method,
        context.Request.Path,
        context.Request.QueryString,
        authorization,
        context.TraceIdentifier);

    try
    {
        await next(context);
    }
    finally
    {
        stopwatch.Stop();
        logger.LogDebug(
            "HTTP response {StatusCode} for {Method} {Path}; DurationMs={DurationMs}; TraceIdentifier={TraceIdentifier}",
            context.Response.StatusCode,
            context.Request.Method,
            context.Request.Path,
            stopwatch.ElapsedMilliseconds,
            context.TraceIdentifier);
    }
});

// Add the authentication and authorization middleware to the request pipeline
// (with routing enabled so the controllers below can be mapped).
app.UseAgents(useRouting: true);

// Map the default agent endpoints: GET "/" and the agent message endpoints.
// Authorization is required automatically when AddAgentAuthorization enabled it above.
app.MapDefaultAgentEndpoints();

if (app.Environment.IsDevelopment() || app.Environment.EnvironmentName == "Playground")
{
    app.UseDeveloperExceptionPage();
    app.MapControllers().AllowAnonymous();
}
else
{
    app.MapControllers();
}

var logger = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("Startup");

logger.LogInformation("AgentFrameworkWeather is starting up. Environment: {EnvironmentName}", app.Environment.EnvironmentName);

app.Run();