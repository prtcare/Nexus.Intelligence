using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Nexus.Platform.Contracts.Secrets;
using Nexus.Platform.Core;
using Nexus.Platform.Providers.OpenAI;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7A.1 / item 4: deterministic documentation and configuration consistency.
//
// WHY THIS EXISTS. The operator guidance for the provider credential was WRONG in a way no test
// could see: `README.md` told an operator to put the credential value under
// `Platform:Providers:OpenAI:ApiKey` using `set-openai-key.ps1`, while the service binds
// `Platform:Providers:OpenAI:ApiKeyRef` and resolves that reference through `ISecretResolver`. An
// operator following the instruction put the credential somewhere the resolution path never reads
// and got a provider 401 - a failure that looks like a bad key rather than like bad guidance.
//
// SUBSEQUENT DISPOSITION. `set-openai-key.ps1` was RETIRED on 2026-09-13 by owner decision;
// provider credential configuration belongs to AI Head. The paragraph above is kept as the record
// of why this file exists. The script is not a supported operator mechanism in any repository, so
// no future guidance may route an operator to it - including to populate the Platform smoke
// host's store.
//
// Prose cannot be tested. Three things that were prose can be:
//   1. the settings files this repository commits,
//   2. the provider configuration keys the documentation SHOWS as configuration,
//   3. the reference namespace the registered resolver actually uses.
//
// Each check is paired with a control that makes it FAIL, so none of them can pass by being unable
// to see anything - the same non-vacuity rule the W7A secret proofs follow.
public sealed class W7a1DocumentationConsistencyTests
{
    // ---------------------------------------------------------------------------------------------
    // The vocabulary.
    // ---------------------------------------------------------------------------------------------

    // The config path this service's provider options actually bind.
    private const string ProviderConfigPrefix = "Platform.Providers.OpenAI";

    private static readonly StringComparer KeyComparer = StringComparer.OrdinalIgnoreCase;

    // ---------------------------------------------------------------------------------------------
    // 1. Committed settings files never carry a secret-VALUED key.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void CommittedSettings_NeverCarryASecretValuedKey()
    {
        var settingsFiles = Directory
            .GetFiles(ApiProjectDirectory, "appsettings*.json", SearchOption.TopDirectoryOnly)
            .ToArray();

        Assert.NotEmpty(settingsFiles);

        var offenders = new List<string>();

        foreach (var file in settingsFiles)
        {
            foreach (var (path, value) in ReadJsonLeaves(file))
            {
                var reason = SecretValuedKeyReason(path, value);
                if (reason is not null)
                {
                    offenders.Add($"{Path.GetFileName(file)} :: {path} :: {reason}");
                }
            }
        }

        Assert.True(
            offenders.Count == 0,
            "A committed settings file carries a secret-VALUED key. CONFIGURATION_STANDARDS.md section 6: " +
            "configuration holds a REFERENCE to a secret, ISecretResolver holds the path to its value, and " +
            "neither holds the value. Offenders: " + string.Join(" | ", offenders));
    }

    // CONTROL. Without this, a leaf reader that silently returned nothing would make the assertion
    // above pass forever.
    [Fact]
    public void SecretValuedKeyCheck_CanFail_OnAKnownBadKey()
    {
        Assert.NotNull(SecretValuedKeyReason("Platform.Providers.OpenAI.ApiKey", "sk-not-a-real-value"));
        Assert.NotNull(SecretValuedKeyReason("Platform.Providers.OpenAI.Password", "hunter2"));
        Assert.NotNull(SecretValuedKeyReason("Platform.Providers.OpenAI.ApiKeyRef", string.Empty));

        // An empty reference is a missing reference, not an acceptable one.
        Assert.Null(SecretValuedKeyReason("Platform.Providers.OpenAI.ApiKeyRef", "NEXUS_OPENAI_API_KEY"));
        Assert.Null(SecretValuedKeyReason("Platform.Providers.OpenAI.Model", "gpt-4.1"));

        // And the live settings file must actually be READABLE, or the check above is looking at
        // nothing. appsettings.json is committed and non-empty by construction.
        var leaves = ReadJsonLeaves(Path.Combine(ApiProjectDirectory, "appsettings.json")).ToArray();

        Assert.NotEmpty(leaves);
        Assert.Contains(leaves, l => l.Path == $"{ProviderConfigPrefix}.ApiKeyRef");
    }

    // ---------------------------------------------------------------------------------------------
    // 2. The documentation shows only provider config keys the options type actually binds.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void DocumentedProviderConfigKeys_AreBoundProperties()
    {
        var bound = typeof(OpenAIOptions)
            .GetProperties()
            .Select(p => p.Name)
            .ToHashSet(KeyComparer);

        var documented = DocumentationFiles
            .SelectMany(file => ShownConfigPaths(File.ReadAllText(file)))
            .Where(path => path.StartsWith(ProviderConfigPrefix + ".", StringComparison.OrdinalIgnoreCase))
            .Distinct(KeyComparer)
            .ToArray();

        // NON-VACUITY: the documentation must actually show the binding. If this ever stops being
        // true, the assertion below has nothing to check and this test would pass by default.
        Assert.True(
            documented.Length > 0,
            $"No provider configuration key is shown in a code block in {string.Join(", ", DocumentationFiles.Select(Path.GetFileName))}. " +
            "The operator guidance no longer shows what to configure, so this check is vacuous.");

        var unbound = documented
            .Where(path => !bound.Contains(path[(ProviderConfigPrefix.Length + 1)..]))
            .ToArray();

        Assert.True(
            unbound.Length == 0,
            "The documentation shows a provider configuration key that OpenAIOptions does not bind. " +
            $"OpenAIOptions binds exactly: {string.Join(", ", bound.OrderBy(n => n, KeyComparer))}. " +
            $"Unbound keys shown: {string.Join(", ", unbound)}. " +
            "A documented key the runtime never reads is how the operator ends up with a 401 instead of a " +
            "configuration error.");

        // The reference key is the one that matters most, so it is required by name rather than left
        // to the check above.
        Assert.Contains(ProviderConfigPrefix + ".ApiKeyRef", documented, KeyComparer);

        // Negative control: the extractor reads a key the options type does not bind, from a code
        // block shaped exactly like the one the README shipped before W7A.1. The block is the input
        // form the extractor reads, so the control supplies one rather than bare JSON.
        const string SupersededGuidance = "```json\n" +
            "{ \"Platform\": { \"Providers\": { \"OpenAI\": { \"ApiKey\": \"<credential>\" } } } }\n" +
            "```";

        var control = ShownConfigPaths(SupersededGuidance).ToArray();

        Assert.Contains(ProviderConfigPrefix + ".ApiKey", control, KeyComparer);
        Assert.DoesNotContain(ProviderConfigPrefix + ".ApiKey", bound, KeyComparer);

        // And the control has to survive the SAME rule that rejects it in a real document, not just
        // be visible to the extractor.
        Assert.NotNull(SecretValuedKeyReason(ProviderConfigPrefix + ".ApiKey", "<credential>"));
    }

    // ---------------------------------------------------------------------------------------------
    // 3. The reference namespace the docs name is the one the registered resolver uses.
    // ---------------------------------------------------------------------------------------------

    // The README states that Platform:Providers:OpenAI:ApiKeyRef holds an ENVIRONMENT VARIABLE NAME,
    // because AddNexusPlatform binds EnvironmentSecretResolver and its namespace is the process
    // environment. That is the claim this test proves, against the composition root the API actually
    // calls - not against a copy of it. If the registration ever changes to a store-backed resolver,
    // this fails and the documentation has to change with it.
    [Fact]
    public async Task RegisteredSecretResolver_ResolvesTheReferenceFromTheProcessEnvironment()
    {
        using var provider = BuildCompositionRoot();

        var resolver = provider.GetRequiredService<ISecretResolver>();
        Assert.Equal("Nexus.Platform.Contracts", typeof(ISecretResolver).Assembly.GetName().Name);

        // A uniquely named environment variable holding a NON-SECRET placeholder. The value is
        // irrelevant to the proof; what is proved is where the resolver looks for it.
        var reference = "NEXUS_W7A1_PROBE_" + Guid.NewGuid().ToString("N");
        var placeholder = "not-a-credential";

        Environment.SetEnvironmentVariable(reference, placeholder);

        try
        {
            Assert.Equal(placeholder, await resolver.ResolveAsync(reference));
        }
        finally
        {
            Environment.SetEnvironmentVariable(reference, null);
        }

        // NEGATIVE CONTROL: a reference that is not in the environment resolves to null - the
        // contract's "no such secret" signal - and never falls back to a configuration value. A
        // resolver that could find the value anywhere else would make the README's instruction to
        // put it in the environment merely one option among several.
        Assert.Null(await resolver.ResolveAsync(reference));
        Assert.Null(await resolver.ResolveAsync(string.Empty));
    }

    private static ServiceProvider BuildCompositionRoot()
    {
        var services = new ServiceCollection();
        services.AddNexusPlatform(new ConfigurationBuilder().Build());

        return services.BuildServiceProvider();
    }

    // ---------------------------------------------------------------------------------------------
    // Shared helpers.
    // ---------------------------------------------------------------------------------------------

    private static string RepositoryRoot { get; } = FindRepositoryRoot();

    private static string ApiProjectDirectory => Path.Combine(RepositoryRoot, "src", "Nexus.Intelligence.Api");

    private static string[] DocumentationFiles { get; } =
    [
        Path.Combine(RepositoryRoot, "README.md"),
        Path.Combine(RepositoryRoot, "AGENTS.md"),
    ];

    /// <summary>
    /// Walks up from the test output directory to the folder holding the solution file. The test
    /// binary's depth is a build detail; the solution file is the stable anchor.
    /// </summary>
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
            $"Could not locate Nexus.Intelligence.slnx above '{AppContext.BaseDirectory}'. The " +
            "documentation consistency checks cannot run without the repository root.");
    }

    /// <summary>
    /// Every leaf of a JSON settings file as a dotted path and its string value. Non-string leaves
    /// are reported with an empty value; only the key name is inspected.
    /// </summary>
    private static IEnumerable<(string Path, string Value)> ReadJsonLeaves(string file)
        => WalkJson(JsonDocument.Parse(File.ReadAllText(file)).RootElement, string.Empty);

    private static IEnumerable<(string Path, string Value)> WalkJson(JsonElement element, string path)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    var childPath = path.Length == 0 ? property.Name : path + "." + property.Name;

                    if (property.Value.ValueKind is JsonValueKind.Object)
                    {
                        foreach (var leaf in WalkJson(property.Value, childPath))
                        {
                            yield return leaf;
                        }
                    }
                    else
                    {
                        yield return (childPath, property.Value.ValueKind is JsonValueKind.String
                            ? property.Value.GetString() ?? string.Empty
                            : property.Value.ToString());
                    }
                }

                break;

            default:
                yield return (path, element.ToString());
                break;
        }
    }

    /// <summary>
    /// Returns why a key is a defect, or <see langword="null"/> when the key is acceptable.
    /// </summary>
    private static string? SecretValuedKeyReason(string path, string value)
    {
        var leaf = path.Split('.').Last();

        if (CredentialVocabulary.IsReferenceName(leaf))
        {
            return string.IsNullOrWhiteSpace(value)
                ? "a secret reference key is present but empty; an empty reference resolves to no secret and " +
                  "presents as a provider 401 rather than as a configuration error"
                : null;
        }

        return CredentialVocabulary.IsCredentialShaped(leaf)
            ? $"'{leaf}' is shaped like a secret VALUE and does not end in 'Ref'"
            : null;
    }

    /// <summary>
    /// The provider configuration paths a document SHOWS as configuration: nothing outside a fenced
    /// code block, so prose that names a key in order to warn about it is not read as a binding.
    /// </summary>
    private static IEnumerable<string> ShownConfigPaths(string documentText)
    {
        foreach (Match block in Regex.Matches(documentText, "```[a-zA-Z]*\\r?\\n(.*?)```", RegexOptions.Singleline))
        {
            var body = block.Groups[1].Value;

            if (TryReadJsonPaths(body, out var jsonPaths))
            {
                foreach (var path in jsonPaths)
                {
                    yield return path;
                }

                continue;
            }

            foreach (Match key in Regex.Matches(body, "[A-Za-z][A-Za-z0-9]*(?::[A-Za-z][A-Za-z0-9]*)+"))
            {
                yield return key.Value.Replace(':', '.');
            }
        }
    }

    private static bool TryReadJsonPaths(string candidate, out string[] paths)
    {
        paths = [];

        try
        {
            using var document = JsonDocument.Parse(candidate);
            paths = WalkJson(document.RootElement, string.Empty).Select(l => l.Path).ToArray();

            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }
}
