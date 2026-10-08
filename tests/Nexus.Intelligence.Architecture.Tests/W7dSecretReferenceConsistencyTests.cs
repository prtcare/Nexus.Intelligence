using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7D TASK 1: the secret-reference name is one name, and three files have to agree about it.
//
// WHY THIS EXISTS. The estate declared the OpenAI credential's reference in three places and two of
// them agreed:
//
//   config/providers.json                        OPENAI_API_KEY          <- the migrated catalogue
//   appsettings Platform:Providers:OpenAI:ApiKeyRef         NEXUS_OPENAI_API_KEY
//   appsettings Ai:Registry:Providers[openai]               NEXUS_OPENAI_API_KEY
//
// Nothing failed. No test went red, no build broke, and no request errored - because a secret
// reference is a NAME that is resolved at the moment a provider is used, and no provider is enabled.
// The disagreement was invisible precisely because the estate is inert, and it would have surfaced
// as a 401 on the first day someone activated a provider: a failure that reads like a bad credential
// rather than like two files disagreeing about what a variable is called.
//
// So this is not a test about a string. It is a test that the three declarations are ONE name, made
// while the estate is still inert enough for the answer to be cheap to fix.
//
// WHAT IT DOES NOT DO. It never reads, resolves or compares a credential VALUE, and it has none to
// read. Every value it inspects is a variable NAME. REQUIRES_HUMAN_SECRET_ROTATION remains active and
// this file neither weakens nor advances it.
public sealed class W7dSecretReferenceConsistencyTests
{
    // The approved reference. Human-approved, and the one the runtime resolves.
    private const string ApprovedReference = "NEXUS_OPENAI_API_KEY";

    // ---------------------------------------------------------------------------------------------
    // 1. The three declarations of the SAME provider are one name.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheThreeDeclarationsOfTheOpenAiReference_AreOneName()
    {
        var catalogue = CatalogueReferences();
        var registry = RegistryReferences();
        var runtime = RuntimeApiKeyReference();

        // The runtime binding resolves the approved name. This is the declaration that actually
        // matters, because it is the one the resolver is handed.
        Assert.Equal(ApprovedReference, runtime);

        // ...and the registry names the same variable, so a governance record and a runtime binding
        // cannot describe different variables for one provider.
        Assert.True(registry.ContainsKey("openai"), "The registry declares no 'openai' provider.");
        Assert.Equal(runtime, registry["openai"]);

        // ...and so does the migrated catalogue, which is the declaration that was wrong.
        Assert.True(catalogue.ContainsKey("openai"), "The catalogue declares no 'openai' provider.");
        Assert.Equal(runtime, catalogue["openai"]);

        // NEGATIVE: the vendor-conventional name is not the approved name, and the test is not
        // passing because both happen to be the same string.
        Assert.NotEqual("OPENAI_API_KEY", ApprovedReference);
    }

    [Fact]
    public void EveryProviderDeclaredInBothPlaces_UsesOneReferenceName()
    {
        // The general rule behind the specific one. A provider declared in the catalogue AND in the
        // registry has two statements about which variable holds its credential, and two statements
        // that can differ are two statements that will.
        var catalogue = CatalogueReferences();
        var registry = RegistryReferences();

        var shared = catalogue.Keys
            .Intersect(registry.Keys, StringComparer.Ordinal)
            .OrderBy(id => id, StringComparer.Ordinal)
            .ToArray();

        // NON-VACUITY: the rule is applied to a non-empty set, and to the provider whose name was
        // actually reconciled. A rule that ranged over nothing would pass on any input.
        Assert.NotEmpty(shared);
        Assert.Contains("openai", shared);

        Assert.All(shared, id => Assert.True(
            string.Equals(catalogue[id], registry[id], StringComparison.Ordinal),
            $"Provider '{id}' names two different secret references: the catalogue says "
            + $"'{catalogue[id]}' and the registry says '{registry[id]}'. One provider has one "
            + "credential variable, and the resolver reads whichever of these it is handed."));
    }

    // ---------------------------------------------------------------------------------------------
    // 2. A RATIFIED reference is an estate name. An unratified one is left alone.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void NoRatifiedReference_IsVendorConventional()
    {
        // "Ratified" means the registry declares the provider, which means an operator recorded a
        // governance entry for it. Those are the providers whose references the estate has actually
        // adopted, and every one of them must use the estate's own naming.
        var registry = RegistryReferences();
        var catalogue = CatalogueReferences();

        Assert.NotEmpty(registry);

        // A registry provider that declares no reference has nothing for this rule to inspect, and
        // dropping it quietly would let the rule pass by checking fewer entries than it claims to. The
        // count assertion is what makes the filter honest rather than convenient.
        var declared = registry
            .Where(entry => entry.Value is not null)
            .ToArray();

        Assert.Equal(registry.Count, declared.Length);

        Assert.All(declared, entry => Assert.True(
            entry.Value!.StartsWith("NEXUS_", StringComparison.Ordinal),
            $"Provider '{entry.Key}' is declared in the registry with the reference "
            + $"'{entry.Value}', which is not an estate-owned name."));

        // CONTROL, and the reason this rule is about RATIFICATION rather than about the whole file:
        // the catalogue still carries vendor-conventional names for providers nobody has ratified,
        // and the rule above deliberately permits them. Asserting that here means the check above
        // cannot pass by the catalogue being uniformly NEXUS_-prefixed, which would make it
        // indistinguishable from a rule that inspects nothing.
        var unratified = catalogue
            .Where(entry => !registry.ContainsKey(entry.Key))
            .Where(entry => entry.Value is not null)
            .ToArray();

        Assert.NotEmpty(unratified);
        Assert.Contains(
            unratified,
            entry => !entry.Value!.StartsWith("NEXUS_", StringComparison.Ordinal));
    }

    // ---------------------------------------------------------------------------------------------
    // 3. A reference is a NAME. No value is in any of the files this test reads.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheCatalogueAndTheRegistry_CarryNamesAndNoValues()
    {
        // The reference fields hold names. A value reaching one is the disclosure this whole family of
        // guards exists to prevent, and the shape rule is the check that catches a pasted one.
        var values = CatalogueReferences().Values
            .Concat(RegistryReferences().Values)
            .Where(value => value is not null)
            .ToArray();

        Assert.NotEmpty(values);

        Assert.All(values, value => Assert.True(
            Nexus.Intelligence.Contracts.AiProviderRegistration.IsWellFormedSecretReference(value),
            $"'{value}' is not shaped like an environment-variable name."));

        // No value anywhere is a credential VALUE. The needles are vendor key prefixes and a JSON
        // private-key marker, none of which a variable name can contain.
        foreach (var file in ConfigFiles())
        {
            var text = File.ReadAllText(file);

            Assert.DoesNotContain("sk-", text, StringComparison.Ordinal);
            Assert.DoesNotContain("BEGIN ", text, StringComparison.Ordinal);
        }

        // NON-VACUITY: the scan reads files that exist and are non-empty, so a clean result is the
        // absence of a needle rather than the absence of a file.
        Assert.All(ConfigFiles(), file => Assert.NotEmpty(File.ReadAllText(file)));
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    private static string RepositoryRoot { get; } = FindRepositoryRoot();

    private static string ApiSettingsFile =>
        Path.Combine(RepositoryRoot, "src", "Nexus.Intelligence.Api", "appsettings.json");

    private static string ProviderCatalogueFile =>
        Path.Combine(RepositoryRoot, "config", "providers.json");

    private static string[] ConfigFiles() =>
        [ApiSettingsFile, ProviderCatalogueFile];

    /// <summary>Provider id to secret reference, from the migrated catalogue. Nulls included.</summary>
    private static IReadOnlyDictionary<string, string?> CatalogueReferences()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(ProviderCatalogueFile));

        var providers = document.RootElement.GetProperty("providers");

        return providers
            .EnumerateArray()
            .ToDictionary(
                provider => provider.GetProperty("ProviderId").GetString()!,
                provider => provider.TryGetProperty("SecretReference", out var reference)
                    && reference.ValueKind == JsonValueKind.String
                        ? reference.GetString()
                        : null,
                StringComparer.Ordinal);
    }

    /// <summary>Provider id to secret reference, from the authoritative W7C registry.</summary>
    private static IReadOnlyDictionary<string, string?> RegistryReferences()
    {
        var registry = new ConfigurationBuilder()
            .AddJsonFile(ApiSettingsFile, optional: false)
            .Build()
            .GetSection("Ai:Registry")
            .Get<Nexus.Intelligence.Core.Registry.AiRegistryConfiguration>()
            ?? new Nexus.Intelligence.Core.Registry.AiRegistryConfiguration();

        return registry.Providers
            .Where(provider => !string.IsNullOrWhiteSpace(provider.ProviderId))
            .ToDictionary(
                provider => provider.ProviderId!,
                provider => provider.SecretReference,
                StringComparer.Ordinal);
    }

    /// <summary>The reference the provider options actually bind at runtime.</summary>
    private static string? RuntimeApiKeyReference()
        => new ConfigurationBuilder()
            .AddJsonFile(ApiSettingsFile, optional: false)
            .Build()["Platform:Providers:OpenAI:ApiKeyRef"];

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);

        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "Nexus.Intelligence.slnx")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        throw new InvalidOperationException(
            $"Could not locate Nexus.Intelligence.slnx above '{AppContext.BaseDirectory}'. The W7D "
            + "secret reference consistency checks cannot run without the repository root.");
    }
}
