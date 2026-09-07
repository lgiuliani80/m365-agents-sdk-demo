// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using AgentFrameworkWeather;
using AgentFrameworkWeather.Agent;
using Azure.Core;
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
using System.Reflection;
using System.ClientModel;
using System.Diagnostics;

var builder = WebApplication.CreateBuilder(args);

var isAgents365Enabled = builder.Configuration["Agent365Observability"] != null;

builder.Configuration.AddUserSecrets(Assembly.GetExecutingAssembly());
BotCertificateBootstrapper.Configure(builder.Configuration);
builder.Services.AddControllers();
builder.Services.AddHealthChecks();
builder.Services.AddHttpClient("WebClient", client => client.Timeout = TimeSpan.FromSeconds(600));
builder.Services.AddHttpContextAccessor();

// Configure defaults for Aspire dashboard
builder.ConfigureOtelProviders();

if (isAgents365Enabled)
{
    builder.AddA365Tracing(configure: config => config.WithAgentFramework());
}

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
        b => b.AddAgentAspNetAuthentication()
    );

// Register IChatClient with correct types
builder.Services.AddSingleton<IChatClient>(sp =>
{
    var confSvc = sp.GetRequiredService<IConfiguration>();
    var endpoint = confSvc["AIServices:AzureOpenAI:Endpoint"] ?? string.Empty;
    var deployment = confSvc["AIServices:AzureOpenAI:DeploymentName"] ?? string.Empty;

    AssertionHelpers.ThrowIfNullOrEmpty(endpoint, "AIServices:AzureOpenAI:Endpoint configuration is missing and required.");
    AssertionHelpers.ThrowIfNullOrEmpty(deployment, "AIServices:AzureOpenAI:DeploymentName configuration is missing and required.");

    // Convert endpoint to Uri
    var endpointUri = new Uri(endpoint);

    AzureOpenAIClient client;
    var apiKey = confSvc["AIServices:AzureOpenAI:ApiKey"];
    if (!string.IsNullOrWhiteSpace(apiKey))
    {
        client = new AzureOpenAIClient(endpointUri, new ApiKeyCredential(apiKey));
    }
    else
    {
        TokenCredential credential;
        if (builder.Environment.IsDevelopment())
        {
            credential = new DefaultAzureCredential();
        }
        else
        {
            var managedIdentityClientId =
                confSvc["AZURE_CLIENT_ID"]
                ?? confSvc["AIServices:AzureOpenAI:ManagedIdentityClientId"];
            if (string.IsNullOrWhiteSpace(managedIdentityClientId))
            {
                throw new InvalidOperationException(
                    "AZURE_CLIENT_ID (or AIServices:AzureOpenAI:ManagedIdentityClientId as an override) is required when API key authentication is disabled outside Development.");
            }

            credential = new ManagedIdentityCredential(
                ManagedIdentityId.FromUserAssignedClientId(managedIdentityClientId));
        }

        client = new AzureOpenAIClient(endpointUri, credential);
    }

    // Create and return the AzureOpenAIClient's ChatClient
    return client.GetChatClient(deployment).AsIChatClient();
});

// Add Agent 365 baggage to every turn and log conversations to transcript files.
builder.Services.AddSingleton(sp =>
{
    var confSvc = sp.GetRequiredService<IConfiguration>();
    var logFolder = confSvc["ConversationLogFolder"];

     var agentMiddlewares = new List<Microsoft.Agents.Builder.IMiddleware>();

     if (isAgents365Enabled)
     {
         agentMiddlewares.Add(new BaggageTurnMiddleware());
     }
     if (!string.IsNullOrEmpty(logFolder))
     {
         agentMiddlewares.Add(new TranscriptLoggerMiddleware(new FileTranscriptLogger(logFolder)));
     }

    return agentMiddlewares.ToArray();
});

var app = builder.Build();

#if LOG_REQUESTS
// Log inbound requests before authentication runs. Use for debugging and development only. 
// Do not use in production.
app.Use(async (context, next) =>
{
    var logger = context.RequestServices
        .GetRequiredService<ILoggerFactory>()
        .CreateLogger("RequestLogging");
    var stopwatch = Stopwatch.StartNew();

    logger.LogDebug(
        "HTTP request {Method} {Path}{QueryString}; Headers={Headers}; TraceIdentifier={TraceIdentifier}",
        context.Request.Method,
        context.Request.Path,
        context.Request.QueryString,
        string.Join(
            ';',
            context.Request.Headers.Select(x =>
                x.Key.Equals("Authorization", StringComparison.OrdinalIgnoreCase)
                || x.Key.Equals("Cookie", StringComparison.OrdinalIgnoreCase)
                || x.Key.Equals("Set-Cookie", StringComparison.OrdinalIgnoreCase)
                    ? $"[{x.Key}=REDACTED]"
                    : $"[{x.Key}={x.Value}]")),
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
#endif

// Add the authentication and authorization middleware to the request pipeline
// (with routing enabled so the controllers below can be mapped).
app.UseAgents(useRouting: true);
app.MapHealthChecks("/health").AllowAnonymous();

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