using System;
using System.Collections.Generic;
using System.Linq;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Registry;
using Xunit;

namespace Nexus.Intelligence.Tests.Registry;

// W7C TASK 9, the registry half: the parse guards, the secret-reference guard, and the negative
// fixtures that show each guard can actually fail.
//
// WHAT THIS SUITE IS FOR. The router tests prove the router refuses what it should. They cannot prove
// that a refusal was ever reachable, because a fixture that cannot express "unapproved" is
// indistinguishable from a router that cannot see approval. These tests exercise the layer where a
// configuration file becomes a registration, so the fixtures the router tests rely on are shown to be
// loadable, and each guard is shown to fire on input that violates it.
//
// Every guard here is paired with a control: the violating input is refused AND the corrected input
// is accepted. Without the second half, a parser that threw on everything would pass.
public sealed class ConfiguredAiRegistryTests
{
    // ---------------------------------------------------------------------------------------------
    // 1. Configuration becomes registrations, and the defaults fail closed.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ARegisteredModel_IsReachableByCapabilityAndByIdentifier()
    {
        var registry = Load(Providers: [Provider("prov-a")], Models: [Model("model-a", "prov-a")]);

        Assert.Equal(1, registry.Count);
        Assert.True(registry.TryGetModel("model-a", out var model), "model-a is not resolvable.");
        Assert.Equal("prov-a", model!.ProviderId);
        Assert.True(registry.TryGetProvider("prov-a", out var provider), "prov-a is not resolvable.");
        Assert.Equal("prov-a", provider!.ProviderId);

        var forCapability = registry.ListForCapability(CapabilityId.Parse(AiCapabilities.CodeReview));

        Assert.Equal("model-a", Assert.Single(forCapability).ModelId);
    }

    [Fact]
    public void AProviderEntry_WithNoApprovalDeclared_LoadsAsUnapproved()
    {
        // Absent must mean refused, not "whatever the enum's zero is". This is the W7C reading of the
        // fail-closed rule, and it is what makes an appsettings file that forgets an Approval key ship
        // a route that cannot be used rather than one that can.
        var registry = Load(Providers: [Provider("prov-a", approval: null)], Models: [Model("model-a", "prov-a")]);

        Assert.True(registry.TryGetProvider("prov-a", out var provider));
        Assert.Equal(AiGovernanceApprovalStatus.Unregistered, provider!.Approval);

        // NON-VACUITY: naming an approval produces that approval, so the default above is a decision
        // about absence and not a parser that cannot read the field.
        var approved = Load(Providers: [Provider("prov-a")], Models: [Model("model-a", "prov-a")]);

        Assert.True(approved.TryGetProvider("prov-a", out var granted));
        Assert.Equal(AiGovernanceApprovalStatus.Approved, granted!.Approval);
    }

    [Fact]
    public void AnEntryMissingARequiredField_RefusesToLoad()
    {
        // The registry fails at COMPOSITION, not at the first request that needed a route. A malformed
        // file that loaded and produced an unroutable model would surface as a routing refusal and
        // point the investigation at the router.
        var anonymous = Model("model-a", "prov-a");
        anonymous.GovernanceRationale = null;

        var refused = Assert.Throws<InvalidOperationException>(() => Load(
            Providers: [Provider("prov-a")],
            Models: [anonymous]));

        Assert.Contains("GovernanceRationale", refused.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void TwoModelsWithOneIdentifier_RefuseToLoad()
    {
        // Duplicates are refused rather than last-one-wins, because which of the two survived is not
        // something the file says and not something an operator could predict.
        var duplicate = Assert.Throws<InvalidOperationException>(() => Load(
            Providers: [Provider("prov-a")],
            Models: [Model("model-a", "prov-a"), Model("model-a", "prov-a")]));

        Assert.Contains("model-a", duplicate.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ANegativeProviderWeight_RefusesToLoad()
    {
        // A weight multiplies the ranking score, so a negative one inverts the operator's own stated
        // preference: the route they ranked highest sorts last, and the estate still looks healthy.
        var negative = Assert.Throws<InvalidOperationException>(() => Load(
            Providers: [Provider("prov-a", weight: -1.0)],
            Models: [Model("model-a", "prov-a")]));

        Assert.Contains("Weight", negative.Message, StringComparison.Ordinal);

        // CONTROL: zero is accepted. It is the honest way to say "reachable, but carrying no weight in
        // the ordering", and refusing it would force an operator to choose between a wrong number and
        // removing the provider entirely.
        var zero = Load(
            Providers: [Provider("prov-a", weight: 0.0)],
            Models: [Model("model-a", "prov-a")]);

        Assert.True(zero.TryGetProvider("prov-a", out var weightless));
        Assert.Equal(0.0, weightless!.Weight);
    }

    // ---------------------------------------------------------------------------------------------
    // 2. The secret reference: a NAME is stored, a VALUE is refused, and no value is ever held.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ASecretReference_IsStoredAsAName()
    {
        var registry = Load(
            Providers: [Provider("prov-a", secretReference: "NEXUS_OPENAI_API_KEY")],
            Models: [Model("model-a", "prov-a")]);

        Assert.True(registry.TryGetProvider("prov-a", out var provider));

        // The approved reference, by name, unchanged. Not the vendor-conventional OPENAI_API_KEY: the
        // estate's approved reference is a different string and substituting one for the other would
        // resolve to nothing.
        Assert.Equal("NEXUS_OPENAI_API_KEY", provider!.SecretReference);
    }

    [Theory]
    [InlineData("sk-proj-abc123DEF456ghi789")]  // A credential value: lower case and hyphens.
    [InlineData("sk-ant-api03-XyZ")]            // A different vendor's value shape.
    [InlineData("nexus_openai_api_key")]        // Lower case, so not an environment-variable name.
    [InlineData("NEXUS-OPENAI-KEY")]            // Hyphens, which no shell accepts in a variable name.
    [InlineData("NEXUS.OPENAI.KEY")]            // Dots, likewise - and the shape a pasted path takes.
    public void ASecretReferenceThatIsNotShapedLikeAName_RefusesToLoad(string reference)
    {
        // Every published vendor key format contains a character the shape rule cannot match, so a
        // value pasted where a name belongs is refused. The refusal also tells the operator to rotate,
        // because a credential that reached a file has to be treated as disclosed.
        var refused = Assert.Throws<InvalidOperationException>(() => Load(
            Providers: [Provider("prov-a", secretReference: reference)],
            Models: [Model("model-a", "prov-a")]));

        Assert.Contains("SecretReference", refused.Message, StringComparison.Ordinal);
        Assert.Contains("rotate", refused.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void TheRegistrysSerialization_CarriesTheReferenceNameAndNoValue()
    {
        // The directive's exit condition is that no secret VALUE exists in registry serialization. A
        // shape check alone cannot establish that, so this asserts it the only way it can be asserted
        // from inside the process: serialize what the registry actually holds and inspect every leaf.
        var registry = Load(
            Providers: [Provider("prov-a", secretReference: "NEXUS_OPENAI_API_KEY")],
            Models: [Model("model-a", "prov-a")]);

        Assert.True(registry.TryGetProvider("prov-a", out var provider));
        Assert.True(registry.TryGetModel("model-a", out var model));

        var providerJson = System.Text.Json.JsonSerializer.Serialize(provider);
        var modelJson = System.Text.Json.JsonSerializer.Serialize(model);

        // The reference NAME is present, because a registry that could not name the variable would not
        // be usable.
        Assert.Contains("NEXUS_OPENAI_API_KEY", providerJson, StringComparison.Ordinal);

        // Exactly ONE property of a provider registration is credential-bearing, and it is the
        // reference. A second one appearing is the event this test exists to catch - a "resolved
        // value", a "cached key", a "connection string" - and it would be caught here rather than by
        // reading a diff.
        var credentialKeys = JsonLeaves(providerJson)
            .Select(leaf => leaf.Path.Split('.').Last())
            .Where(key => key.Contains("Secret", StringComparison.OrdinalIgnoreCase)
                || key.Contains("Key", StringComparison.OrdinalIgnoreCase)
                || key.Contains("Credential", StringComparison.OrdinalIgnoreCase)
                || key.Contains("Token", StringComparison.OrdinalIgnoreCase)
                || key.Contains("Password", StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(["SecretReference"], credentialKeys);

        // No leaf of either registration equals a credential value. The needles are the exact strings
        // the refusal theory uses, so if storage of a value were ever introduced anywhere in the parse,
        // the value would appear here.
        var needles = CredentialValueCanaries;
        var haystack = providerJson + modelJson;

        Assert.All(
            needles,
            needle => Assert.DoesNotContain(needle, haystack, StringComparison.Ordinal));

        // NON-VACUITY: the same scan over a string that DOES contain a needle finds it, so the scan
        // above returns clean because there is nothing to find rather than because it cannot look.
        Assert.Contains(needles[0], "prefix " + needles[0] + " suffix", StringComparison.Ordinal);
    }

    [Fact]
    public void NoProviderRegistrationMember_CanHoldAnythingButAName()
    {
        // The shape check is not the guarantee; the TYPE is. A registration has no member that could
        // hold a secret, and this is the inventory that makes that claim reviewable: a new string
        // member has to be considered here rather than arriving unnoticed.
        var stringMembers = typeof(AiProviderRegistration)
            .GetProperties()
            .Where(p => p.PropertyType == typeof(string))
            .Select(p => p.Name)
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(
            ["AdapterIdentity", "ApprovedBy", "DisplayName", "GovernanceRationale", "ProviderId", "SecretReference"],
            stringMembers);

        // Of those, exactly one is credential-bearing, and it holds a NAME. The other five are an
        // identifier and three pieces of free text - none of which any code resolves as a secret, so a
        // value landing in one of them is a disclosure to be cleaned up rather than a credential the
        // estate would then use.
        Assert.Equal("SecretReference", stringMembers.Single(name => name.EndsWith("Ref", StringComparison.Ordinal)
            || name == "SecretReference"));

        // The approved reference satisfies the shape rule, which is what lets it live on the type at
        // all - and is why the shape rule is not a test of WHICH name is approved. That is a policy
        // fact, asserted where the policy is recorded, not a property of the string.
        Assert.True(AiProviderRegistration.IsWellFormedSecretReference("NEXUS_OPENAI_API_KEY"));
    }

    [Fact]
    public void AProviderWithNoSecretReference_StillLoads()
    {
        // A provider that requires no credential is a legitimate registration. The guard is about the
        // SHAPE of a reference that is present, not about requiring one - refusing absence would make
        // a local adapter unregisterable.
        var registry = Load(
            Providers: [Provider("prov-local", secretReference: null)],
            Models: [Model("model-a", "prov-local")]);

        Assert.True(registry.TryGetProvider("prov-local", out var provider));
        Assert.Null(provider!.SecretReference);
    }

    // ---------------------------------------------------------------------------------------------
    // 3. Health is two independent questions, and both fail closed.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ModelHealthDoesNotFallBackToProviderHealth()
    {
        // A provider can be throttling as a whole while one model on it is withdrawn, so the two
        // readings are independent. This test exists because the router checks both, and a fixture that
        // declared only provider health would route nothing while looking correct.
        var registry = Load(
            Providers: [Provider("prov-a")],
            Models: [Model("model-a", "prov-a")],
            Health: [new AiHealthConfigurationEntry { ProviderId = "prov-a", State = "Available" }]);

        Assert.Equal(AiModelHealthState.Available, registry.GetProviderHealth("prov-a"));

        // NON-VACUITY: the provider reads Available and the model reads Unknown, from one file. If the
        // model value were inherited these would be equal.
        Assert.Equal(AiModelHealthState.Unknown, registry.GetModelHealth("model-a", "prov-a"));

        // CONTROL: declaring the model's own health produces it.
        var declared = Load(
            Providers: [Provider("prov-a")],
            Models: [Model("model-a", "prov-a")],
            Health:
            [
                new AiHealthConfigurationEntry { ProviderId = "prov-a", State = "Available" },
                new AiHealthConfigurationEntry { ProviderId = "prov-a", ModelId = "model-a", State = "Degraded" },
            ]);

        Assert.Equal(AiModelHealthState.Degraded, declared.GetModelHealth("model-a", "prov-a"));
    }

    [Fact]
    public void NoHealthDeclared_ReadsUnknown_WhichIsNotRoutable()
    {
        var registry = Load(Providers: [Provider("prov-a")], Models: [Model("model-a", "prov-a")]);

        Assert.Equal(AiModelHealthState.Unknown, registry.GetProviderHealth("prov-a"));
        Assert.Equal(AiModelHealthState.Unknown, registry.GetModelHealth("model-a", "prov-a"));
        Assert.False(registry.GetModelHealth("model-a", "prov-a").IsRoutable());
    }

    // ---------------------------------------------------------------------------------------------
    // 4. The parse is by NAME. A numeral is refused rather than bound by position.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ATrustTierWrittenAsANumeral_RefusesToLoad()
    {
        // Enum.TryParse("1") succeeds and IsDefined(1) is true whenever a member holds 1, so the
        // obvious strict parse accepts this and the estate runs with whichever trust tier is numbered 1.
        // Names are required, which is also what makes renumbering a member unable to change what a
        // deployed configuration file means.
        var numeral = Assert.Throws<InvalidOperationException>(() => Load(
            Providers: [Provider("prov-a", trust: "1")],
            Models: [Model("model-a", "prov-a")]));

        Assert.Contains("trust tier", numeral.Message, StringComparison.Ordinal);
        Assert.Contains("Names are required", numeral.Message, StringComparison.Ordinal);

        // CONTROL: the name binds, case-insensitively.
        var byName = Load(
            Providers: [Provider("prov-a", trust: "approved")],
            Models: [Model("model-a", "prov-a")]);

        Assert.True(byName.TryGetProvider("prov-a", out var trusted));
        Assert.Equal(AiProviderTrustTier.Approved, trusted!.Trust);
    }

    // ---------------------------------------------------------------------------------------------
    // 5. An EMPTY registry is loadable, and it refuses everything.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AnEmptyRegistry_LoadsAndServesNothing()
    {
        // The committed appsettings declares models and providers but approves none, and an estate with
        // no Ai:Registry section at all gets this. Both must compose: a registry that could not be
        // constructed empty would make "no AI providers are configured" a startup failure rather than
        // a routing refusal.
        var empty = ConfiguredAiRegistry.Empty;

        Assert.Equal(0, empty.Count);
        Assert.Empty(empty.ListForCapability(CapabilityId.Parse(AiCapabilities.CodeReview)));
        Assert.False(empty.TryGetModel("model-a", out _));
        Assert.False(empty.TryGetProvider("prov-a", out _));

        // NON-VACUITY: the same query against a populated registry returns something.
        var populated = Load(Providers: [Provider("prov-a")], Models: [Model("model-a", "prov-a")]);

        Assert.NotEmpty(populated.ListForCapability(CapabilityId.Parse(AiCapabilities.CodeReview)));
    }

    [Fact]
    public void AModelNamingAnUnregisteredProvider_StillLoads()
    {
        // Referential integrity is NOT enforced at load, deliberately. Refusing it here would take the
        // whole estate down over one stale model identifier; instead the model is registered and the
        // router refuses any route to it by name. That is the difference between a degraded estate and
        // an unavailable one, and the router test for ProviderNotRegistered is the other half of it.
        var registry = Load(Providers: [], Models: [Model("model-orphan", "prov-missing")]);

        Assert.Equal(1, registry.Count);
        Assert.True(registry.TryGetModel("model-orphan", out var orphan));
        Assert.Equal("prov-missing", orphan!.ProviderId);
        Assert.False(registry.TryGetProvider("prov-missing", out _));
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    /// <summary>
    /// Credential-shaped strings that must never appear in registry serialization.
    /// </summary>
    /// <remarks>
    /// The same values the shape-refusal theory offers as input, which is what makes the two halves of
    /// the argument meet: those strings cannot be loaded, and these tests show they are not stored.
    /// </remarks>
    private static readonly string[] CredentialValueCanaries =
    [
        "sk-proj-abc123DEF456ghi789",
        "sk-ant-api03-XyZ",
    ];

    /// <summary>Every leaf of a serialized object, as a dotted path and its rendered value.</summary>
    private static IEnumerable<(string Path, string Value)> JsonLeaves(string json)
    {
        using var document = System.Text.Json.JsonDocument.Parse(json);

        // Materialised before the document is disposed. The enumeration is lazy, so returning it
        // directly would hand the caller elements backed by a document that is already gone - which
        // fails as an ObjectDisposedException from inside a LINQ operator rather than as anything
        // resembling a JSON problem.
        return Leaves(document.RootElement, string.Empty).ToArray();

        static IEnumerable<(string Path, string Value)> Leaves(
            System.Text.Json.JsonElement element,
            string path)
        {
            switch (element.ValueKind)
            {
                case System.Text.Json.JsonValueKind.Object:
                    foreach (var property in element.EnumerateObject())
                    {
                        var child = path.Length == 0 ? property.Name : $"{path}.{property.Name}";

                        foreach (var leaf in Leaves(property.Value, child))
                        {
                            yield return leaf;
                        }
                    }

                    break;

                case System.Text.Json.JsonValueKind.Array:
                    foreach (var item in element.EnumerateArray())
                    {
                        foreach (var leaf in Leaves(item, path))
                        {
                            yield return leaf;
                        }
                    }

                    break;

                default:
                    yield return (path, element.ToString());
                    break;
            }
        }
    }

    private static ConfiguredAiRegistry Load(
        IEnumerable<AiProviderConfigurationEntry> Providers,
        IEnumerable<AiModelConfigurationEntry> Models,
        IEnumerable<AiHealthConfigurationEntry>? Health = null)
        => new(new AiRegistryConfiguration
        {
            Provenance = "W7C registry test fixture.",

            // A model whose routing objective is unknown would fail the router's construction, not
            // this parse, so the fixture states a valid one rather than relying on the default.
            Routing = new AiRoutingConfigurationEntry { Objective = "Balanced", FallbackDepth = 1 },
            Providers = [.. Providers],
            Models = [.. Models],
            Health = [.. Health ?? []],
        });

    private static AiProviderConfigurationEntry Provider(
        string id,
        bool enabled = true,
        string? secretReference = "NEXUS_TEST_API_KEY",
        string? trust = "Approved",
        string? approval = "Approved",
        double? weight = null) => new()
        {
            ProviderId = id,
            DisplayName = id,
            AdapterIdentity = "Nexus.Intelligence.Tests.Adapter",
            Capabilities = [AiCapabilities.CodeReview, AiCapabilities.ChatComplete],
            Enabled = enabled,
            SecretReference = secretReference,
            PermitsRemoteEgress = false,
            Trust = trust,
            Priority = 0,
            Weight = weight,
            Approval = approval,
            MaxClassification = "Public",
            ApprovedBy = approval == "Approved" ? "test-owner" : null,
            GovernanceRationale = "W7C registry test fixture.",
        };

    private static AiModelConfigurationEntry Model(
        string id,
        string providerId,
        bool enabled = true,
        string? availability = "Available")
        => new()
        {
            ModelId = id,
            ProviderId = providerId,
            DisplayName = id,
            Capabilities = [AiCapabilities.CodeReview, AiCapabilities.ChatComplete],
            MaxContextTokens = 200_000,
            MaxOutputTokens = 8_192,
            InputModalities = ["Text"],
            OutputModalities = ["Text"],
            Reasoning = "High",
            RelativeSpeed = "Normal",
            Availability = availability,
            Enabled = enabled,
            CostMetadataReference = null,
            InputCostPer1kTokens = null,
            OutputCostPer1kTokens = null,
            CostCurrency = null,
            Approval = "Approved",
            MaxClassification = "Public",
            ApprovedBy = "test-owner",
            GovernanceRationale = "W7C registry test fixture.",
        };
}
