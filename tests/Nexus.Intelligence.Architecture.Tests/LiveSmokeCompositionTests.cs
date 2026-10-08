using Microsoft.Extensions.Configuration;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Registry;
using Nexus.Intelligence.LiveSmokeHost;
using Nexus.Platform.Providers.OpenAI;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

/// <summary>
/// Binds and validates the live provider smoke fixture's configuration, <b>without a credential</b>.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why this exists, stated without dressing it up.</b> The provider-specific smoke tests cannot run
/// on a machine with no OpenAI key — and the historical credential for this estate must not be read,
/// so no such run is available here. The honest consequence would be that the re-homed fixture ships
/// with its configuration never once parsed by the engine that will parse it. That is the shape of
/// the failure this estate keeps recording: something that looks tested because it is written down.
/// </para>
/// <para>
/// <b>These tests buy a real, bounded guarantee.</b> Everything asserted here is on the path between
/// the fixture's JSON and a routing decision: the document binds, the registry accepts every declared
/// member, the model is reachable for the capability the fixture asks for, the route is healthy, the
/// adapter the registry points at is a type that exists, and the cost gates will not refuse the
/// request before a vendor is reached. A defect in any of those fails here, for free, on every build.
/// </para>
/// <para>
/// <b>What it does not buy, and must never be read as buying.</b> Nothing here contacts a provider.
/// A green result is not evidence that OpenAI is reachable, that the credential is valid, that the
/// model <c>gpt-4.1-mini</c> exists, or that a turn completes. Item 12, 13 and 14 of the migration
/// runbook are satisfied only by <c>Nexus.Intelligence.LiveSmokeTests</c> executing against a live
/// vendor, and that suite has not been executed in this environment. This file converts
/// "unexecuted" into "unexecuted but configuration-validated" and claims nothing further.
/// </para>
/// <para>
/// <b>It binds <c>LiveEstate.BuildConfiguration()</c> rather than re-building a document here.</b>
/// That is deliberate: the assertions are then about the bytes the live estate actually boots on. A
/// test that reconstructed an equivalent configuration would validate its own reconstruction, which
/// is a fact about this file and not about the fixture.
/// </para>
/// </remarks>
public sealed class LiveSmokeCompositionTests
{
    /// <summary>The capability the fixture's estate is composed to serve.</summary>
    private static readonly CapabilityId Capability = CapabilityId.Parse(AiCapabilities.ChatComplete);

    /// <summary>
    /// The fixture's registry, bound through the same configuration binder a host uses.
    /// </summary>
    /// <remarks>
    /// A misspelt section name, a mistyped JSON key or a member the binder cannot reach all produce
    /// the same silent symptom — an empty registry — which this method converts into a visible one by
    /// asserting the declaration arrived at all. An empty registry does not throw; it refuses every
    /// route, which is exactly why "it composed without error" is not evidence of anything.
    /// </remarks>
    private static AiRegistryConfiguration BoundRegistryConfiguration()
    {
        var configuration = LiveEstate.BuildConfiguration()
            .GetSection(AiRegistryConfiguration.SectionName)
            .Get<AiRegistryConfiguration>();

        Assert.True(
            configuration is not null,
            $"the live fixture declares no {AiRegistryConfiguration.SectionName} section that the binder can read");

        Assert.True(
            configuration.Providers.Count == 1,
            $"the live fixture must declare exactly one provider, bound {configuration.Providers.Count}. "
            + "A count of zero means the section did not bind; a count above one means the fixture would "
            + "route over a provider this suite never asserted anything about.");

        Assert.True(
            configuration.Models.Count == 1,
            $"the live fixture must declare exactly one model, bound {configuration.Models.Count}");

        return configuration;
    }

    // ============================================================================================
    // The registry the router will read.
    // ============================================================================================

    [Fact]
    public void LiveFixture_Registry_ParsesThroughTheEstatesOwnParser()
    {
        // The constructor validates structure and every named member — trust tier, approval status,
        // health state, secret-reference shape — and throws naming the offending entry. So this one
        // call is the whole of "the fixture's configuration is legal", and it is the parse the live
        // suite would have performed for the first time on a paid run.
        var registry = new ConfiguredAiRegistry(BoundRegistryConfiguration());

        Assert.Equal(1, registry.Count);
        Assert.Equal(1, ((IAiProviderRegistry)registry).Count);
    }

    [Fact]
    public void LiveFixture_Model_IsReachableForTheCapabilityItAsksFor()
    {
        var registry = new ConfiguredAiRegistry(BoundRegistryConfiguration());

        // This is the lookup the router performs first. If it returns nothing the estate refuses the
        // request with a routing failure and never constructs a provider call — a green-looking
        // fixture that proves nothing about OpenAI.
        var routes = registry.ListForCapability(Capability);

        var route = Assert.Single(routes);
        Assert.Equal(LiveEstate.ModelId, route.ModelId);
        Assert.Equal(LiveEstate.ProviderId, route.ProviderId);
        Assert.True(route.Enabled, "the fixture's model must be enabled or no route is ever produced");
    }

    [Fact]
    public void LiveFixture_Provider_IsApprovedAndPermittedToLeaveTheMachine()
    {
        var registry = new ConfiguredAiRegistry(BoundRegistryConfiguration());

        Assert.True(
            registry.TryGetProvider(LiveEstate.ProviderId, out var provider),
            $"the fixture's provider '{LiveEstate.ProviderId}' is not in its own registry");
        Assert.NotNull(provider);

        // Approval, because the estate is fail-closed: an entry with no approval is refused by
        // governance before a provider is reached. Stated as an assertion rather than trusted,
        // because the failure it prevents is invisible — the turn is refused for a governance reason
        // that has nothing to do with the vendor, and reads as a provider fault.
        Assert.True(provider!.Enabled, "the fixture's provider must be enabled");
        Assert.Equal(AiGovernanceApprovalStatus.Approved, provider.Approval);
        Assert.Equal(AiProviderTrustTier.Approved, provider.Trust);

        // The one place in the estate's tests where this is true. Every other suite asserts that
        // egress is refused; this suite exists to make one call.
        Assert.True(provider.PermitsRemoteEgress, "a live smoke fixture must be permitted to reach the vendor");
    }

    [Fact]
    public void LiveFixture_SecretReference_IsANameAndNeverAValue()
    {
        var registry = new ConfiguredAiRegistry(BoundRegistryConfiguration());

        Assert.True(registry.TryGetProvider(LiveEstate.ProviderId, out var provider));
        Assert.NotNull(provider);

        // The fixture names the credential's location and carries nothing else. Both halves matter:
        // the equality says the live suite reads the variable a runner would set, and the shape check
        // is the estate's own guard that the field holds an environment-variable name — a pasted key
        // fails it, because every published vendor key format contains a character the pattern
        // cannot match.
        Assert.Equal(LiveProviderKey.ReferenceName, provider!.SecretReference);

        Assert.True(
            AiProviderRegistration.IsWellFormedSecretReference(provider.SecretReference),
            $"the fixture's secret reference '{provider.SecretReference}' is not shaped like a "
            + "credential's location. It must be a name the estate resolves, never a value.");
    }

    [Fact]
    public void LiveFixture_Route_IsHealthyOrItWouldNotBeRouted()
    {
        var registry = new ConfiguredAiRegistry(BoundRegistryConfiguration());

        // Unreported health is not routable — Unknown is the state the parser produces for an entry
        // nobody declared, so a fixture that forgot its health block would refuse every route while
        // its configuration looked complete.
        Assert.Equal(
            AiModelHealthState.Available,
            registry.GetProviderHealth(LiveEstate.ProviderId));
        Assert.Equal(
            AiModelHealthState.Available,
            registry.GetModelHealth(LiveEstate.ModelId, LiveEstate.ProviderId));
    }

    [Fact]
    public void LiveFixture_AdapterIdentity_NamesATypeThatActuallyExists()
    {
        var registry = new ConfiguredAiRegistry(BoundRegistryConfiguration());

        Assert.True(registry.TryGetProvider(LiveEstate.ProviderId, out var provider));
        Assert.NotNull(provider);

        // The registry records this as a name and deliberately does not load the type — a config file
        // that can instantiate anything is a config file that can instantiate anything, and that
        // decision is not revisited here. But the FIXTURE's claim is checkable, and nothing else
        // checks it: if the adapter were renamed, this pointer would become a false statement in the
        // registry that every reader would believe, with no failure anywhere.
        Assert.Equal(typeof(OpenAIModelGateway).FullName, provider!.AdapterIdentity);
    }

    // ============================================================================================
    // The two cost gates the request must survive before a vendor is reached.
    // ============================================================================================

    [Fact]
    public void LiveFixture_Model_IsUnpriced_SoNoCeilingHadToBeInvented()
    {
        var registry = new ConfiguredAiRegistry(BoundRegistryConfiguration());
        var catalogue = new ConfiguredAiPriceCatalogue(registry);

        var lookup = catalogue.Lookup(LiveEstate.ModelId, LiveEstate.ProviderId, AiProcessingTier.Standard);

        // Deliberate, and the reason is a doctrine rather than a shortcut: a smoke test has no basis
        // for stating a spending ceiling. Inventing one would be the arbitrary production threshold
        // this estate forbids, and a ceiling chosen to be unreachable would be an allowance wearing a
        // control's clothes. Unpriced is admitted by the budget policy below instead. If someone
        // prices this fixture's model without writing a covering rule, the governance cost gate
        // starts refusing the live turn — so this assertion is what makes that change loud and free
        // rather than silent and paid.
        Assert.False(
            lookup.IsFound,
            $"the live fixture's model became priced ({lookup.State}). Either keep it unpriced or "
            + "declare a covering budget rule; a priced route with no rule is refused before the "
            + "provider is reached.");

        Assert.Equal(AiPricingLookupState.NotFound, lookup.State);
    }

    [Fact]
    public void LiveFixture_BudgetPolicy_AdmitsTheUnpricedRouteAndRefusesAnUncoveredPricedOne()
    {
        var operations = LiveEstate.BuildConfiguration()
            .GetSection(AiOperationsConfiguration.SectionName)
            .Get<AiOperationsConfiguration>();

        Assert.True(
            operations is not null,
            $"the live fixture declares no {AiOperationsConfiguration.SectionName} section that the binder can read");

        // BudgetPolicy() parses every named member and throws on an unknown one, so this call is also
        // the fixture's validation that its configuration names real behaviours.
        var policy = operations.BudgetPolicy();

        Assert.True(policy.Available, "the fixture must compose the operational budget plane, not disable it");
        Assert.Empty(policy.Rules);

        // Stated in the fixture's own JSON, and therefore checked as a statement rather than assumed.
        Assert.Equal(AiBudgetUncoveredBehaviour.Refuse, policy.OnUncoveredPricedExecution);

        // NOT stated in the fixture's JSON, because no configuration key binds it — this is the
        // contract's own default, and the live suite's admission depends on it. Pinned here so that
        // a future change to that default fails a fast, free, in-solution test instead of surfacing
        // as an unexplained refusal on a run that spends the owner's money. A comment in the fixture
        // saying "unpriced is allowed" would have been true today and unenforced tomorrow; this is
        // the version of that statement that can fail.
        Assert.Equal(AiBudgetUncoveredBehaviour.Allow, policy.OnUnpricedExecution);
    }

    // ============================================================================================
    // The credential boundary of the fixture itself.
    // ============================================================================================

    [Fact]
    public void LiveFixture_Configuration_CarriesNoCredentialValue()
    {
        // Every leaf of the fixture's document is a string, so a credential that leaked into the
        // fixture would have to leak as one. This walks the whole tree rather than the two fields
        // that are meant to hold a reference. Nothing here reads the environment variable —
        // LiveProviderKey exposes existence and not value — so this test cannot be the thing that
        // materialises a credential into a test log on a machine that has one.
        var values = LiveEstate.BuildConfiguration()
            .AsEnumerable()
            .Where(pair => !string.IsNullOrEmpty(pair.Value))
            .Select(pair => (pair.Key, Value: pair.Value!))
            .ToArray();

        Assert.NotEmpty(values);

        // Two shapes catch the two ways a value arrives: a name the estate itself would accept as a
        // reference, and a published vendor key.
        var referenceShaped = values
            .Where(pair => AiProviderRegistration.IsWellFormedSecretReference(pair.Value))
            .ToArray();

        // There are exactly two, and the count is asserted rather than the presence, because both are
        // load-bearing halves of one fact. The registry entry says which secret a route needs; the
        // adapter's options say which one to resolve. A third would be a second declaration of the
        // same credential somewhere nobody is looking; a missing one would mean a route that names no
        // secret, or an adapter told to resolve nothing.
        Assert.Equal(2, referenceShaped.Length);

        // Both must name the SAME variable. Two reference-shaped values that disagreed would be worse
        // than none: the estate would route on one credential and resolve another, and the mismatch
        // would first appear as an authentication failure against the vendor.
        Assert.All(referenceShaped, pair => Assert.Equal(LiveProviderKey.ReferenceName, pair.Value));

        // And they are the two fields that are supposed to hold a reference, named exactly — so a
        // reference that arrived somewhere else, in a field with no business carrying one, is a
        // failure rather than a curiosity.
        Assert.Equal(
            [
                "Ai:Registry:Providers:0:SecretReference",
                "Platform:Providers:OpenAI:ApiKeyRef",
            ],
            referenceShaped.Select(pair => pair.Key).Order(StringComparer.Ordinal));

        // A vendor key format, named directly. The estate's shape rule is built to reject this, and
        // asserting the rejection separately means a future loosening of that rule cannot quietly
        // turn this test into one that passes while a key sits in the file.
        var keyShaped = values
            .Where(pair => pair.Value.StartsWith("sk-", StringComparison.OrdinalIgnoreCase))
            .ToArray();

        Assert.True(
            keyShaped.Length == 0,
            "the live fixture carries a vendor key rather than a reference, at: "
            + string.Join(", ", keyShaped.Select(pair => pair.Key)));
    }
}
