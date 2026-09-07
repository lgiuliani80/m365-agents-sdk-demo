using System.Security.Cryptography.X509Certificates;

namespace AgentFrameworkWeather;

internal static class BotCertificateBootstrapper
{
    private const string ConnectionSettingsPath = "Connections:BotServiceConnection:Settings";

    public static void Configure(IConfigurationManager configuration)
    {
        var authType = configuration[$"{ConnectionSettingsPath}:AuthType"];
        if (!string.Equals(authType, "Certificate", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var pemPath = configuration["BotAuthentication:Certificate:PemPath"];

        if (string.IsNullOrWhiteSpace(pemPath) || !File.Exists(pemPath))
        {
            throw new InvalidOperationException(
                $"Certificate authentication requires a readable PEM file at '{pemPath}'.");
        }

        using var clientCertificate = X509Certificate2.CreateFromPemFile(pemPath);
        if (!clientCertificate.HasPrivateKey)
        {
            throw new InvalidOperationException(
                "The configured PEM does not contain an X.509 certificate with a matching unencrypted private key.");
        }

        using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
        store.Open(OpenFlags.ReadWrite);

        var existing = store.Certificates.Find(
            X509FindType.FindByThumbprint,
            clientCertificate.Thumbprint,
            validOnly: false);

        if (existing.Count == 0)
        {
            store.Add(clientCertificate);
        }

        configuration.AddInMemoryCollection(new Dictionary<string, string?>
        {
            [$"{ConnectionSettingsPath}:CertThumbprint"] = clientCertificate.Thumbprint
        });
    }
}
