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

        var pfxPath = configuration["BotAuthentication:Certificate:PfxPath"];
        var passwordPath = configuration["BotAuthentication:Certificate:PasswordPath"];

        if (string.IsNullOrWhiteSpace(pfxPath) || !File.Exists(pfxPath))
        {
            throw new InvalidOperationException(
                $"Certificate authentication requires a readable PFX file at '{pfxPath}'.");
        }

        if (string.IsNullOrWhiteSpace(passwordPath) || !File.Exists(passwordPath))
        {
            throw new InvalidOperationException(
                $"Certificate authentication requires a readable password file at '{passwordPath}'.");
        }

        var pfxBytes = Convert.FromBase64String(File.ReadAllText(pfxPath));
        var password = File.ReadAllText(passwordPath);
        var certificates = new X509Certificate2Collection();
        certificates.Import(
            pfxBytes,
            password,
            X509KeyStorageFlags.PersistKeySet | X509KeyStorageFlags.UserKeySet);

        var clientCertificate = certificates
            .OfType<X509Certificate2>()
            .FirstOrDefault(certificate => certificate.HasPrivateKey)
            ?? throw new InvalidOperationException("The configured PFX does not contain a certificate with a private key.");

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
