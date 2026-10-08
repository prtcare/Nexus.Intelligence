using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Nexus.Intelligence.Api.DependencyInjection;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Registry;
using Nexus.Platform.Core;
using Nexus.Platform.Providers.OpenAI;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7C TASK 7 (OOS-3), TASK 8 and TASK 10 as repository-level facts.
//
// WHY THIS FILE EXISTS. Three of W7C's exit conditions are claims about the REPOSITORY rather than
// about a value a test can call: that a hard-coded model default is gone, that the committed registry
// approves nothing, and that no secret value is anywhere in the configuration. Each is the kind of
// claim that is true on the day it is written and quietly false six months later, because the code
// that made it true looks exactly like the code that undoes it.
//
// So each is checked from outside the code that implements it: reflection over the provider's options
// type, a scan of the source tree, and a parse of the committed appsettings. Every check carries a
// control that makes it fail, because a scan that finds nothing and a scan that cannot look are
// indistinguishable from the outside.
public sealed class W7cRegistryBoundaryTests
{
    // ---------------------------------------------------------------------------------------------
    // TASK 7 (OOS-3): the recorded hard-coded model default is gone.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheProviderOptionsType_NoLongerCarriesAModelDefault()
    {
        // The recorded OOS-3 finding was `public string Model { get; set; } = "gpt-4.1";`. The property
        // is gone rather than defaulted-to-empty, because a property that exists is a property someone
        // binds, and a bound empty string is a model identifier the estate would route to.
        Assert.Null(typeof(OpenAIOptions).GetProperty("Model"));

        // CONTROL: the type is the right type and its credential seam is untouched. W7C moved a model
        // default out of provider code and did not alter credential handling, and this is the assertion
        // that would fail if it had.
        Assert.NotNull(typeof(OpenAIOptions).GetProperty("ApiKeyRef"));
    }

    [Fact]
    public void NoExecutableCode_InTheRepositoryNamesAModel()
    {
        // TASK 1's "do not hardcode the permanent model list into router code", stated as a property of
        // the whole tree rather than of one file. A model identifier appearing in executable code is the
        // hedge this lane exists to remove: it is a fact about which models exist that no configuration
        // file can revise.
        var offenders = new List<string>();

        foreach (var file in SourceFiles())
        {
            var code = StripComments(File.ReadAllText(file));

            if (ModelIdentifierLiteral.IsMatch(code))
            {
                offenders.Add(Path.GetRelativePath(RepositoryRoot, file));
            }
        }

        Assert.True(
            offenders.Count == 0,
            "Executable code names a model. Model identifiers belong to configuration: "
            + string.Join(", ", offenders));

        // NON-VACUITY: the SAME scan finds the identifier in the configuration file where it belongs, so
        // a clean result above is the absence of a literal rather than a scanner that cannot match one.
        var settings = File.ReadAllText(Path.Combine(ApiProjectDirectory, "appsettings.json"));

        Assert.Matches(ModelIdentifierLiteral, settings);

        // ...and it finds one in synthetic code, so it is not merely matching JSON punctuation.
        Assert.Matches(ModelIdentifierLiteral, "var model = \"openai:gpt-4.1\";");
    }

    [Fact]
    public void StripComments_RemovesThePlacesTheIdentifierIsOnlyBeingDiscussed()
    {
        // The scan above is only as good as this step, so it is tested directly rather than trusted. The
        // removals here were written by W7C itself: the comments recording what was removed name the
        // identifier, and a scan that could not tell a comment from a statement would fail on its own
        // documentation.
        const string sample = """
            /// <summary>Was <c>openai:gpt-4.1</c>.</summary>
            // W7C TASK 7: this named "openai:gpt-4.1".
            /* "openai:gpt-4.1" in a block comment */
            var ok = "no identifier here";
            """;

        var stripped = StripComments(sample);

        Assert.DoesNotMatch(ModelIdentifierLiteral, stripped);
        Assert.Contains("var ok", stripped, StringComparison.Ordinal);

        // CONTROL: a literal in an actual statement survives the strip, so the strip does not simply
        // delete every quotation mark it sees.
        Assert.Matches(ModelIdentifierLiteral, StripComments("var model = \"openai:gpt-4.1\";"));
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 8 and the committed state: the estate ships refusing, and names no secret.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheCommittedRegistry_ApprovesNothingAndEnablesNothing()
    {
        // The exit condition is a registry that is authoritative and an estate that cannot invoke. A
        // committed entry with Enabled true and an approval would be an estate that routes to a provider
        // whose historical credential still requires human rotation - so this is the assertion that
        // keeps the committed state refusing, not a claim that it currently does.
        var registry = ReadCommittedRegistry();

        Assert.NotEmpty(registry.Providers);
        Assert.NotEmpty(registry.Models);

        Assert.All(registry.Providers, provider =>
            Assert.False(provider.Enabled, $"Provider '{provider.ProviderId}' is committed enabled."));

        Assert.All(registry.Models, model =>
            Assert.False(model.Enabled, $"Model '{model.ModelId}' is committed enabled."));

        Assert.All(registry.Providers, provider => Assert.Equal("Unregistered", provider.Approval));
        Assert.All(registry.Models, model => Assert.Equal("Unregistered", model.Approval));

        // NON-VACUITY: the registry is not empty, so the assertions above are about entries that exist.
        // An empty file would satisfy every one of them.
        Assert.Contains(registry.Providers, p => p.ProviderId == "openai");
    }

    [Fact]
    public void TheCommittedRegistry_NamesTheApprovedSecretReferenceAndNoOther()
    {
        // The approved reference is NEXUS_OPENAI_API_KEY. The vendor-conventional OPENAI_API_KEY is a
        // different string that resolves to nothing in this estate, so substituting one for the other
        // would break credential resolution in a way that looks like a bad key.
        var settings = File.ReadAllText(Path.Combine(ApiProjectDirectory, "appsettings.json"));
        var registry = ReadCommittedRegistry();

        Assert.Equal("NEXUS_OPENAI_API_KEY", registry.Providers.Single().SecretReference);

        // Every secret-reference field in the committed configuration uses the approved prefix, and no
        // reference in the registry is anything else.
        Assert.All(
            SecretReferenceValues(settings),
            value => Assert.StartsWith("NEXUS_", value, StringComparison.Ordinal));

        // NON-VACUITY: the scan is looking at a non-empty set of references, so the assertion above is
        // about values that exist rather than about nothing.
        Assert.Contains("NEXUS_OPENAI_API_KEY", SecretReferenceValues(settings));

        // And no credential VALUE is in the file. The needles are the ones the behaviour suite offers as
        // input to the shape guard, so the two suites meet.
        Assert.DoesNotContain("sk-", settings, StringComparison.Ordinal);
    }

    [Fact]
    public void EveryCredentialBearingSettingsField_HoldsANameAndNothingElse()
    {
        // The W7C registry contributes credential-bearing fields to the committed settings. This is the
        // claim that those fields hold a NAME - so the two ways a value could get in are both excluded:
        // a value where a name belongs, and a value anywhere at all.
        //
        // The scan keys off the FIELD name rather than the value's shape, because shape alone cannot
        // tell a secret from a currency code: "USD" is upper-case and satisfies the reference-name rule.
        // What makes a field credential-bearing is what it is for, and the field names say so.
        var settingsFiles = Directory
            .GetFiles(ApiProjectDirectory, "appsettings*.json", SearchOption.TopDirectoryOnly)
            .ToArray();

        Assert.NotEmpty(settingsFiles);

        var inspected = new List<string>();

        foreach (var file in settingsFiles)
        {
            using var document = JsonDocument.Parse(File.ReadAllText(file));

            var credentialBearing = Leaves(document.RootElement, string.Empty)
                .Where(leaf => CredentialFieldName.IsMatch(leaf.Path.Split('.').Last()))
                .ToArray();

            inspected.AddRange(credentialBearing.Select(leaf => leaf.Path));

            Assert.All(
                credentialBearing,
                leaf => Assert.True(
                    AiProviderRegistration.IsWellFormedSecretReference(leaf.Value),
                    $"{Path.GetFileName(file)}: '{leaf.Path}' is a credential-bearing field whose value "
                    + "is not shaped like an environment-variable NAME. The registry stores the name of "
                    + "the variable holding a credential and never a value."));

            // No value anywhere in the file is a credential VALUE. The needle is a vendor key prefix,
            // which no name-shaped reference can contain.
            Assert.DoesNotContain("sk-", File.ReadAllText(file), StringComparison.Ordinal);
        }

        // NON-VACUITY: the scan inspected credential-bearing fields rather than none, and the set it
        // found is the one W7C committed.
        Assert.Contains(inspected, path => path.EndsWith("ApiKeyRef", StringComparison.Ordinal));
        Assert.Contains(inspected, path => path.EndsWith("SecretReference", StringComparison.Ordinal));
    }

    // ---------------------------------------------------------------------------------------------
    // The composition root: with no configuration at all, nothing routes.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ComposedWithNoConfiguration_TheRegistryIsEmptyAndNothingRoutes()
    {
        // The end state W7C is required to ship. An estate that has configured nothing gets a router
        // that resolves and refuses - not a router with a built-in model, and not a startup failure.
        var configuration = new ConfigurationBuilder().Build();

        using var serviceProvider = new ServiceCollection()
            .AddNexusPlatform(configuration)
            .AddNexusIntelligence(configuration)
            .BuildServiceProvider();

        var registry = serviceProvider.GetRequiredService<IAiModelRegistry>();

        Assert.Equal(0, registry.Count);

        // One instance answers both registry ports, so there is no second registry to drift from the
        // first.
        Assert.Same(registry, serviceProvider.GetRequiredService<IAiProviderRegistry>());

        // The health port is NOT the registry, and W7E changed that deliberately rather than by
        // accident. TASK 4 requires routing to read a PUBLISHED snapshot and never to probe inline, so
        // health is now the snapshot store's reader - a separate object whose only writer is an
        // out-of-band sweep. This assertion used to require the registry here; it now requires the
        // opposite, because leaving the registry registered as well would put two health sources in the
        // container and make which one routing read a property of registration order.
        var health = serviceProvider.GetRequiredService<IAiModelHealthSource>();

        Assert.IsType<SnapshotAiHealthSource>(health);
        Assert.NotNull(serviceProvider.GetRequiredService<IAiHealthSnapshotStore>());

        // ...and with no configuration nothing has been published, so the snapshot answers Unknown
        // rather than inheriting a health nothing observed. "Unknown" is not routable, which is the
        // same refusal the empty registry produces, reached through the other gate.
        Assert.Equal(
            AiModelHealthState.Unknown,
            health.GetModelHealth("openai:gpt-4.1", "openai"));

        Assert.Equal(AiModelHealthState.Unknown, health.GetProviderHealth("openai"));

        var outcome = serviceProvider.GetRequiredService<IAiCapabilityRouter>().Route(
            new AiCapabilityRequest
            {
                RequestId = "req-w7c-composition",
                Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
                Purpose = "Composition check.",
                Requester = new AiRequesterIdentity
                {
                    Head = CallingHead.Ai,
                    PrincipalId = "principal-w7c",
                    PermissionScope = AiPermissionScope.None,
                    DataScopes = [],
                },
                Input = new TurnInput(TurnInputKind.Task, "hello", []),
                Classification = DataClassification.Public,
                Execution = AiExecutionPolicy.Default,
                IdempotencyKey = "idem-w7c-composition",
            },
            AiPlatformGovernanceAttestation.NotApplicable,
            AiRoutingContext.Unstated);

        Assert.False(outcome.IsRouted);
        Assert.Equal(AiRoutingStatus.CapabilityNotFound, outcome.Status);
        Assert.Null(outcome.Selected);

        // CONTROL: the same composed container routes when a configuration declares one approved model,
        // so the refusal above is the empty registry and not a router that cannot route.
        var populated = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Ai:Registry:Providers:0:ProviderId"] = "prov-a",
                ["Ai:Registry:Providers:0:DisplayName"] = "Provider A",
                ["Ai:Registry:Providers:0:AdapterIdentity"] = "Nexus.Intelligence.Tests.Adapter",
                ["Ai:Registry:Providers:0:Capabilities:0"] = AiCapabilities.ChatComplete,
                ["Ai:Registry:Providers:0:Enabled"] = "true",
                ["Ai:Registry:Providers:0:SecretReference"] = "NEXUS_TEST_API_KEY",
                ["Ai:Registry:Providers:0:Trust"] = "Approved",
                ["Ai:Registry:Providers:0:Approval"] = "Approved",
                ["Ai:Registry:Providers:0:ApprovedBy"] = "test-owner",
                ["Ai:Registry:Providers:0:GovernanceRationale"] = "W7C composition control.",
                ["Ai:Registry:Models:0:ModelId"] = "model-a",
                ["Ai:Registry:Models:0:ProviderId"] = "prov-a",
                ["Ai:Registry:Models:0:DisplayName"] = "Model A",
                ["Ai:Registry:Models:0:Capabilities:0"] = AiCapabilities.ChatComplete,
                ["Ai:Registry:Models:0:Enabled"] = "true",
                ["Ai:Registry:Models:0:Approval"] = "Approved",
                ["Ai:Registry:Models:0:ApprovedBy"] = "test-owner",
                ["Ai:Registry:Models:0:GovernanceRationale"] = "W7C composition control.",
                ["Ai:Registry:Health:0:ProviderId"] = "prov-a",
                ["Ai:Registry:Health:0:State"] = "Available",
                ["Ai:Registry:Health:1:ProviderId"] = "prov-a",
                ["Ai:Registry:Health:1:ModelId"] = "model-a",
                ["Ai:Registry:Health:1:State"] = "Available",
            })
            .Build();

        using var populatedProvider = new ServiceCollection()
            .AddNexusPlatform(populated)
            .AddNexusIntelligence(populated)
            .BuildServiceProvider();

        Assert.Equal(1, populatedProvider.GetRequiredService<IAiModelRegistry>().Count);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    /// <summary>
    /// A vendor-prefixed model identifier in a string literal, or a bare vendor model name.
    /// </summary>
    /// <remarks>
    /// Deliberately narrow. It matches a quoted identifier and the vendor's own naming, which is what a
    /// compiled-in model fact looks like. It does not match the word "model", because most of this
    /// repository is about models and a scan that flagged the subject rather than the fact would be
    /// turned off within a week.
    /// </remarks>
    private static readonly Regex ModelIdentifierLiteral = new(
        "\"[a-z0-9_.-]+:gpt-|\"gpt-[0-9]|\"claude-[0-9]|\"gemini-[0-9]",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>
    /// The field names by which a credential-bearing settings field is recognised.
    /// </summary>
    /// <remarks>
    /// Narrow on purpose. A broader net catching "CostCurrency" because a currency code happens to be
    /// upper-case is a check that would have to be weakened the first time a legitimate all-caps value
    /// appeared, and a weakened check is worse than a narrow one.
    /// </remarks>
    private static readonly Regex CredentialFieldName = new(
        "Ref$|Secret|ApiKey$|Token$|Password|Credential",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static string RepositoryRoot { get; } = FindRepositoryRoot();

    private static string ApiProjectDirectory => Path.Combine(RepositoryRoot, "src", "Nexus.Intelligence.Api");

    /// <summary>Every C# source file in the repository's production tree.</summary>
    private static IEnumerable<string> SourceFiles()
        => Directory
            .GetFiles(Path.Combine(RepositoryRoot, "src"), "*.cs", SearchOption.AllDirectories)
            .Where(file => !file.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.Ordinal)
                && !file.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.Ordinal));

    /// <summary>
    /// Source text with comments removed: line comments, XML documentation, and block comments.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A comment is where this repository RECORDS what it removed, so a scan that could not tell a
    /// comment from a statement would fail on W7C's own documentation of W7C. That is not a hypothetical
    /// awkwardness - it is the reason this helper exists.
    /// </para>
    /// <para>
    /// <b>What it does not do.</b> It is a lexical stripper and not a C# parser: it does not track string
    /// literals, so a comment marker inside a string would be treated as a comment start. In this
    /// codebase that costs nothing, because the scan's purpose is to find a model identifier in
    /// executable code and a false negative requires a string literal containing <c>//</c> on the same
    /// line before a model identifier. It is stated here rather than left for a reader to discover.
    /// </para>
    /// </remarks>
    private static string StripComments(string source)
    {
        var withoutBlocks = Regex.Replace(source, @"/\*.*?\*/", string.Empty, RegexOptions.Singleline);

        return string.Join(
            '\n',
            withoutBlocks
                .Split('\n')
                .Select(line => line.TrimStart().StartsWith("//", StringComparison.Ordinal)
                    ? string.Empty
                    : StripTrailingComment(line)));

        static string StripTrailingComment(string line)
        {
            var index = line.IndexOf("//", StringComparison.Ordinal);

            return index < 0 ? line : line[..index];
        }
    }

    private static AiRegistryConfiguration ReadCommittedRegistry()
        => new ConfigurationBuilder()
            .AddJsonFile(Path.Combine(ApiProjectDirectory, "appsettings.json"), optional: false)
            .Build()
            .GetSection(AiRegistryConfiguration.SectionName)
            .Get<AiRegistryConfiguration>()
            ?? new AiRegistryConfiguration();

    /// <summary>
    /// Every value in the committed settings that is a secret-reference field, by the field's name.
    /// </summary>
    private static IEnumerable<string> SecretReferenceValues(string settings)
    {
        using var document = JsonDocument.Parse(settings);

        return Leaves(document.RootElement, string.Empty)
            .Where(leaf => leaf.Path.EndsWith("Ref", StringComparison.Ordinal)
                || leaf.Path.EndsWith("SecretReference", StringComparison.Ordinal))
            .Select(leaf => leaf.Value)
            .ToArray();
    }

    private static IEnumerable<(string Path, string Value)> Leaves(JsonElement element, string path)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    var child = path.Length == 0 ? property.Name : $"{path}.{property.Name}";

                    foreach (var leaf in Leaves(property.Value, child))
                    {
                        yield return leaf;
                    }
                }

                break;

            case JsonValueKind.Array:
                foreach (var item in element.EnumerateArray())
                {
                    foreach (var leaf in Leaves(item, path))
                    {
                        yield return leaf;
                    }
                }

                break;

            case JsonValueKind.String:
                yield return (path, element.GetString() ?? string.Empty);
                break;
        }
    }

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
            $"Could not locate Nexus.Intelligence.slnx above '{AppContext.BaseDirectory}'. The W7C "
            + "registry boundary checks cannot run without the repository root.");
    }
}
