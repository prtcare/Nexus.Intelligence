using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Registry;
using Nexus.Intelligence.Core.Routing;
using Nexus.Intelligence.Tests.Turns;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Operations;

// W7E TASK 14: the live health snapshot, the reliability gate, and the processing-tier gate.
//
// THE STRUCTURAL CLAIM, AND HOW IT IS TESTED. TASK 4 requires that routing reads a snapshot and never
// probes inline. The behavioural half is asserted here by counting probe invocations across a routing
// call: the count is taken before and after, and it must not move. The structural half is that
// GovernedPath composes the router with SnapshotAiHealthSource - a type with no probe, no network and
// no way to acquire one - so the only writer of the snapshot is a sweep the test drives by hand.
//
// WHY THE HEALTH TESTS PUBLISH RATHER THAN RECONFIGURE. The fixture declares every route Available.
// Every test below that needs an unhealthy route publishes a snapshot contradicting that declaration,
// so what the router acted on can only be the snapshot. A test that edited the declaration instead
// would be testing the seed.
public sealed class W7eHealthAndReliabilityTests
{
    // ---------------------------------------------------------------------------------------------
    // 1. Health is read from the published snapshot, and the router never probes.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AnUnhealthyPrimary_IsSkipped_AndTheHealthyRouteServes()
    {
        var path = GovernedPath.Compose(TwoRoutes());

        Publish(path, (PrimaryProvider, PrimaryModel, AiModelHealthState.Unavailable));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));
        Assert.Equal([AlternateModel], path.Model.ModelsAsked);
    }

    [Fact]
    public void AHealthyPrimary_IsServed_WhichIsWhatMakesTheSkipEvidence()
    {
        // CONTROL for the test above: the same fixture and the same code path, with one state changed.
        var path = GovernedPath.Compose(TwoRoutes());

        Publish(path, (PrimaryProvider, PrimaryModel, AiModelHealthState.Available));

        Run(path);

        Assert.Equal([PrimaryModel], path.Model.ModelsAsked);
    }

    [Theory]
    [InlineData(AiModelHealthState.AuthError)]
    [InlineData(AiModelHealthState.Unavailable)]
    public void EveryStateThatIsNotWorthAttempting_RemovesTheRoute(AiModelHealthState state)
    {
        // The vocabulary TASK 4 requires, asserted rather than assumed. A router that only understood
        // Unavailable would pass the single-state test above and fail here for AuthError, which is what
        // a revoked or mismatched credential actually reports.
        var path = GovernedPath.Compose(TwoRoutes());

        Publish(path, (PrimaryProvider, PrimaryModel, state));

        Run(path);

        Assert.Equal([AlternateModel], path.Model.ModelsAsked);
    }

    [Theory]
    [InlineData(AiModelHealthState.RateLimited)]
    [InlineData(AiModelHealthState.Degraded)]
    public void AThrottledOrDegradedRoute_IsStillAttempted_ItIsDeprioritisedNotRemoved(AiModelHealthState state)
    {
        // The other half of the vocabulary, and the claim that stops the tests above from being read as
        // "anything but Available is refused". RateLimited and Degraded are routable: the estate keeps
        // capacity that is merely struggling, and the ranker is what expresses the preference. A router
        // that dropped them would let a provider's busiest hour take its capacity out of service, which
        // is the opposite of what a failover plane is for.
        var path = GovernedPath.Compose(TwoRoutes());

        Publish(
            path,
            (PrimaryProvider, PrimaryModel, state),
            (AlternateProvider, AlternateModel, state));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));
        Assert.Equal([PrimaryModel], path.Model.ModelsAsked);
    }

    [Fact]
    public void AnAbsentSnapshotEntry_IsNotHealth_SoAnUnpublishedRouteIsNotReachable()
    {
        // TASK 4, and the contract AiHealthSnapshot states: absence is not an entry saying available.
        // Here the snapshot is published from nothing, so the estate has NO routable route at all, and
        // the correct answer is to route nowhere rather than to reach a route nobody has observed.
        var path = GovernedPath.Compose(TwoRoutes());

        PublishExclusively(path, (PrimaryProvider, PrimaryModel, AiModelHealthState.Unavailable));

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));
        Assert.Empty(path.Model.ModelsAsked);
        Assert.Empty(path.Ledger.Entries());
    }

    [Fact]
    public void TheSameSnapshot_WithTheAlternatePublished_IsRouted_WhichIsWhatMakesItEvidence()
    {
        // CONTROL: the same two-route estate, the same unhealthy primary, one row added for the route
        // the test above left unpublished. If absence were silently read as available, the test above
        // would have routed to the alternate and this control would be indistinguishable from it.
        var path = GovernedPath.Compose(TwoRoutes());

        PublishExclusively(
            path,
            (PrimaryProvider, PrimaryModel, AiModelHealthState.Unavailable),
            (AlternateProvider, AlternateModel, AiModelHealthState.Available));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));
        Assert.Equal([AlternateModel], path.Model.ModelsAsked);
    }

    [Fact]
    public void TheSeedRecordsWhatWasDeclared_AndInventsNothing()
    {
        // The snapshot under it all. A configuration that declares no health produces an empty
        // snapshot, and every lookup against it answers Unknown - which is not routable. This is the
        // reason the fixture's HealthFor fills the declaration in: an estate that says nothing about
        // health has said nothing, and W7E does not read that as good news.
        var configuration = new AiRegistryConfiguration
        {
            Provenance = "W7E test fixture.",
            Providers = [Route(PrimaryProvider, priority: 10)],
            Models = [ModelFor(PrimaryModel, PrimaryProvider)],
        };

        var snapshot = SeededAiHealthSnapshot.From(configuration, DateTimeOffset.UtcNow);

        Assert.Equal(SeededAiHealthSnapshot.DeclaredSource, snapshot.Source);
        Assert.Empty(snapshot.Providers);
        Assert.Empty(snapshot.Models);
        Assert.Equal(AiModelHealthState.Unknown, snapshot.ProviderState(PrimaryProvider));
        Assert.Equal(AiModelHealthState.Unknown, snapshot.ModelState(PrimaryModel, PrimaryProvider));
    }

    [Fact]
    public async Task Routing_DoesNotProbe_AndTheSweepIsTheOnlyWriter()
    {
        // TASK 4's structural claim, as a count. A probe that reaches the network cannot be called from
        // a routing decision, and the way to prove it without a network is to count: the sweep calls
        // the probe, and the routing decision does not.
        var configuration = TwoRouteConfiguration();
        var registry = new ConfiguredAiRegistry(configuration);
        var probe = new CountingProbe();
        var store = new InMemoryAiHealthSnapshotStore(
            SeededAiHealthSnapshot.From(configuration, DateTimeOffset.UtcNow));

        var runner = new ConfiguredAiHealthProbeRunner(
            configuration,
            [probe],
            store,
            TimeProvider.System);

        // The sweep reaches every declared provider and every declared model.
        await runner.RunOnceAsync();

        var afterSweep = probe.Targets.Count;
        Assert.True(afterSweep > 0, "The sweep must reach the probe, or the count below proves nothing.");

        // A routing decision over the published snapshot. The count must not move - and the decision
        // must actually have been taken, or "no probe ran" would be a statement about a router that
        // did nothing at all.
        var before = probe.Targets.Count;

        var reliabilityPolicy = AiReliabilityPolicy.Default;
        var circuitPolicy = AiCircuitPolicy.Default;
        var gateHistory = new InMemoryAiReliabilityHistory(TimeProvider.System);

        var outcome = new GovernedCapabilityRouter(
            registry,
            registry,
            new SnapshotAiHealthSource(store),
            new DeterministicAiGovernanceEvaluator(Permissive(registry)),
            new GovernedAiOperationalEligibility(
                new ConfiguredAiPriceCatalogue(registry),
                new ConfiguredAiBudgetEvaluator(AiOperationsBudgetPolicy.NotEvaluated),
                gateHistory,
                reliabilityPolicy,
                new ReplayedAiCircuitBreaker(gateHistory, reliabilityPolicy, circuitPolicy),
                circuitPolicy),
            AiRoutingPolicy.Default,
            TimeProvider.System)
            .Route(Request(), AiPlatformGovernanceAttestation.NotApplicable, AiRoutingContext.Unstated);

        Assert.True(outcome.IsRouted, $"The routing decision must be a real one: {outcome.Reason}");
        Assert.Equal(before, probe.Targets.Count);
    }

    [Fact]
    public async Task ASweepThatReachesNoProbe_LeavesThePublishedStateAlone()
    {
        // NON-VACUITY for the count above, and the other half of the estate's composition: with no probe
        // configured the sweep publishes the declared snapshot unchanged. A count of zero probes would
        // otherwise be equally consistent with a sweep that had silently cleared everything.
        var configuration = TwoRouteConfiguration();
        var store = new InMemoryAiHealthSnapshotStore(
            SeededAiHealthSnapshot.From(configuration, DateTimeOffset.UtcNow));

        var runner = new ConfiguredAiHealthProbeRunner(configuration, [], store, TimeProvider.System);

        var published = await runner.RunOnceAsync();

        Assert.Equal(AiModelHealthState.Available, published.ModelState(PrimaryModel, PrimaryProvider));
        Assert.Equal(AiModelHealthState.Available, published.ModelState(AlternateModel, AlternateProvider));
    }

    // ---------------------------------------------------------------------------------------------
    // 2. Reliability is evidence-backed, not a configuration guess.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ARouteWithABadObservedRecord_IsRefused_OnEvidence()
    {
        // TASK 5: the refusal must rest on observation. The history below is seeded, not configured as
        // a verdict: the gate reads attempts and counts them, and the policy supplies the floor. Nothing
        // tells the gate which route is bad.
        //
        // W7G-R moved the reason code, not the principle. The conditions that used to refuse outright
        // are the conditions that now open a circuit, so the finding reads CircuitOpen where it read
        // ReliabilityTooLow. The route is refused on the same evidence, by the same numbers, and the
        // rejection now says which condition opened the circuit and what would release it.
        var path = GovernedPath.Compose(TwoRoutes(
            history: Observed(),
            reliability: Strict()));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));
        Assert.Equal([AlternateModel], path.Model.ModelsAsked);

        // Refused because of its observed record, and the evidence is on the rejection rather than only
        // in the finding's prose.
        var rejection = Assert.Single(
            outcome.Routing!.OperationalFindings,
            finding => finding.Reason is AiRoutingRejectionReason.CircuitOpen);

        Assert.NotNull(rejection.Reliability);
        Assert.Equal(0, rejection.Reliability!.Successes);
        Assert.Equal(4, rejection.Reliability.Attempts);

        // Which of the opening conditions fired is reported rather than left to be inferred from the
        // numbers: 4 consecutive failures is below Strict()'s ceiling of 10, so the ceiling did not open
        // this circuit — the rate did, on a sample of 4 against a floor of 2. Reading the reason off the
        // snapshot is what stops a reader attributing the refusal to the wrong threshold.
        var circuit = Assert.IsType<AiCircuitSnapshot>(rejection.Circuit);
        Assert.Equal(AiCircuitState.Open, circuit.State);
        Assert.Equal(AiCircuitStateChangeReason.SuccessRateBelowFloor, circuit.Reason);

        // The refusal is dated and bounded, which is the whole difference between this and the
        // permanent refusal it replaces.
        Assert.NotNull(circuit.OpenedAt);
        Assert.NotNull(circuit.CooldownElapsedAt);
        Assert.False(circuit.CooldownElapsed);
        Assert.True(circuit.CooldownElapsedAt > circuit.OpenedAt);

        // And the failures that opened it are still on the record.
        Assert.Equal(4, circuit.FailuresObserved);
        Assert.Equal(4, circuit.AttemptsObserved);
    }

    [Fact]
    public void TheSameFixture_WithTheObservedRecordReversed_ServesThePrimary()
    {
        // CONTROL: the same estate, the same policy, the same number of attempts - only which route
        // they were recorded against has changed. A gate that refused on configuration rather than on
        // evidence could not tell these two apart.
        var path = GovernedPath.Compose(TwoRoutes(
            history: Observed(reversed: true),
            reliability: Strict()));

        Run(path);

        Assert.Equal([PrimaryModel], path.Model.ModelsAsked);
    }

    [Fact]
    public void NoEvidence_UnderAStrictPolicy_IsRefusedAsMissing_NotAsLow()
    {
        // "We do not know" and "we know it is bad" have different remedies. An estate that demanded
        // evidence and got none must be able to say which happened.
        var path = GovernedPath.Compose(TwoRoutes(reliability: Strict()));

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));
        Assert.Empty(path.Model.ModelsAsked);
        Assert.Contains(
            outcome.Routing!.OperationalFindings,
            finding => finding.Reason is AiRoutingRejectionReason.ReliabilityEvidenceMissing);
    }

    [Fact]
    public void NoEvidence_UnderTheShippedPolicy_Routes_SoTheGateTightensWithHistoryRatherThanBlocking()
    {
        // CONTROL for the refusal above, and the reason the W7C suite still passes unchanged: the
        // shipped default does not require evidence, so an estate with no history refuses nothing on
        // reliability grounds.
        var path = GovernedPath.Compose(TwoRoutes(reliability: AiReliabilityPolicy.Default));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));
    }

    [Fact]
    public void TheConsecutiveFailureCeiling_RefusesARouteThatIsCurrentlyFailing()
    {
        // A current signal, checked before the rate. Eight successes then four consecutive failures is a
        // route that is broken NOW, and a success rate diluted across the whole window would not say so.
        //
        // W7G.2 F-6. One clock for the seeded attempts AND for the routing decision that reads them.
        // This test used to stamp its history from DateTimeOffset.UtcNow while the estate read
        // TimeProvider.System, which left the outcome decided by how long the machine took to reach the
        // routing call: the seeded failures sat one minute old against a one-minute cooldown, so a run
        // that reached routing within ~11 ms saw a still-open circuit (refused, test passed) and a slower
        // run saw the cooldown elapsed (released, test failed). A cold isolated run always lost that race
        // and a warm full suite always won it. The frozen clock makes the difference between "opened" and
        // "asked" a value the test chooses, so the same answer is produced on a cold machine, a warm one,
        // and under a debugger.
        var clock = new ControllableTimeProvider();

        var history = new List<AiReliabilityAttempt>();
        history.AddRange(History(PrimaryProvider, PrimaryModel, succeeded: 8, failed: 0, time: clock));
        history.AddRange(History(PrimaryProvider, PrimaryModel, succeeded: 0, failed: 4, time: clock));
        history.AddRange(History(AlternateProvider, AlternateModel, succeeded: 8, failed: 0, time: clock));

        var path = GovernedPath.Compose(TwoRoutes(
            history: history,
            reliability: new AiReliabilityPolicy
            {
                MinimumSampleSize = 4,

                // A floor the primary's overall rate (8 of 12) still clears, so only the consecutive
                // ceiling can produce the refusal. That is what makes this test about the ceiling.
                MinimumSuccessRate = 0.5,
                ConsecutiveFailureCeiling = 3,
                RequireEvidence = true,
            },
            time: clock));

        // Non-vacuity, asserted on the INPUTS and before anything runs. Both facts below are properties
        // of what this test seeded, read from the clock the test owns — so they hold on a cold machine,
        // a warm one, and under a debugger. They are checked first because they explain the assertion
        // that follows: if the seeded failures are not current then the primary route was released by a
        // cooldown elapsing rather than refused by the ceiling, which is the same red result reached by
        // a different road and would otherwise surface as a bare collection diff.
        //
        // Read before Run deliberately. A released primary route is attempted during the run and its
        // success would reset the very evidence being asserted, so a post-run read would describe the
        // outcome rather than the input and could not distinguish the two roads at all.
        var circuit = path.Reliability.EvidenceFor(PrimaryProvider, PrimaryModel);
        Assert.True(
            clock.GetUtcNow() - circuit.LastFailureAt < AiCircuitPolicy.Default.Cooldown,
            "the seeded failures are not recent relative to the cooldown, so this run would be about a "
            + "cooldown elapsing rather than about the consecutive-failure ceiling. This test exists to "
            + "assert the ceiling; make the seeded failures current before asserting it.");
        Assert.Equal(4, circuit.ConsecutiveFailures);

        Run(path);

        Assert.Equal([AlternateModel], path.Model.ModelsAsked);
    }

    [Fact]
    public void ExecutingARoute_TeachesTheHistoryAboutIt()
    {
        // The write side of TASK 5: the recorder records an attempt per invocation, so the gate's
        // evidence is produced by the estate's own traffic rather than by an operator's guess.
        var path = GovernedPath.Compose(TwoRoutes(tokensIn: 5, tokensOut: 5));

        Run(path);

        var evidence = path.Reliability.EvidenceFor(PrimaryProvider, PrimaryModel);

        Assert.Equal(1, evidence.Attempts);
        Assert.Equal(1, evidence.Successes);
        Assert.Equal(0, evidence.ConsecutiveFailures);
        Assert.Null(evidence.LastFailureCategory);
    }

    [Fact]
    public void AFailedPrimary_TeachesTheHistoryThatItFailed()
    {
        // The same, for the case the gate exists for. The failed attempt is recorded with its category,
        // so the next routing decision has a reason to skip the route rather than a bare count.
        var path = GovernedPath.Compose(TwoRoutes(failingModels: [PrimaryModel]));

        var outcome = Run(path);

        // It failed over, so a provider was reached - and the primary's failure is on the record.
        Assert.True(Succeeded(outcome));

        var evidence = path.Reliability.EvidenceFor(PrimaryProvider, PrimaryModel);
        Assert.Equal(1, evidence.Attempts);
        Assert.Equal(0, evidence.Successes);
        Assert.Equal(1, evidence.ConsecutiveFailures);
        Assert.NotNull(evidence.LastFailureCategory);
    }

    // ---------------------------------------------------------------------------------------------
    // 3. Processing tier is metadata-driven, not name-inferred.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AModelThatDoesNotDeclareTheTier_IsRefused_AsProcessingTierUnsupported()
    {
        // TASK 6: tier support comes from the registration's declared metadata and from nothing else.
        // This model declares Batch; the turn is dispatched at Standard.
        var path = GovernedPath.Compose(new GovernedPathOptions
        {
            Models =
            [
                GovernedPath.ModelEntry(
                    "prov-w7d:model-a",
                    "prov-w7d",
                    processingTiers: [nameof(AiProcessingTier.Batch)]),
            ],
        });

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));
        Assert.Empty(path.Model.ModelsAsked);
        Assert.Contains(
            outcome.Routing!.OperationalFindings,
            finding => finding.Reason is AiRoutingRejectionReason.ProcessingTierUnsupported);
    }

    [Fact]
    public void AModelThatDeclaresTheTier_IsServed()
    {
        // CONTROL: one field changed - the declared tier list now contains the tier the work runs at.
        var path = GovernedPath.Compose(new GovernedPathOptions
        {
            Models =
            [
                GovernedPath.ModelEntry(
                    "prov-w7d:model-a",
                    "prov-w7d",
                    processingTiers: [nameof(AiProcessingTier.Standard), nameof(AiProcessingTier.Batch)]),
            ],
        });

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));
        Assert.Equal([ "prov-w7d:model-a" ], path.Model.ModelsAsked);
    }

    [Fact]
    public void AModelWhoseConfigurationSaysNothingAboutTiers_DeclaresStandardAndNotUniversality()
    {
        // The narrow reading, asserted at the registration rather than through a routing outcome,
        // because this is a statement about what the metadata means. Silence is not a claim: an entry
        // that says nothing about tiers supports exactly the interactive case every model supports, and
        // a gate that read absence as universality would be inferring support - which TASK 6 forbids.
        var path = GovernedPath.Compose(new GovernedPathOptions());

        var registration = Assert.Single(
            path.Registry.ListForCapability(CapabilityId.Parse(AiCapabilities.ChatComplete)));

        Assert.True(registration.SupportsTier(AiProcessingTier.Standard));
        Assert.False(registration.SupportsTier(AiProcessingTier.Batch));
        Assert.False(registration.SupportsTier(AiProcessingTier.Priority));
        Assert.False(registration.SupportsTier(AiProcessingTier.Flex));
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    /// <summary>Publishes the current snapshot with the caller's rows applied over it.</summary>
    /// <remarks>
    /// <para>
    /// <b>It overrides rather than replaces.</b> The seed the fixture composed already carries every
    /// declared route at Available, and a publish that discarded it would make every unnamed route
    /// Unknown - so a test that meant to take ONE route out of service would have taken the rest with
    /// it, and would pass for a reason it did not name.
    /// </para>
    /// <para>
    /// Each row is applied at both scopes, provider-wide and model-scoped, so a test is not silently
    /// relying on the snapshot's provider-to-model fallback to carry its state to the route.
    /// </para>
    /// </remarks>
    private static void Publish(GovernedPath path, params (string ProviderId, string ModelId, AiModelHealthState State)[] rows)
    {
        var current = path.Health.Current;

        PublishExclusively(path, [.. Rows(current), .. rows]);
    }

    /// <summary>The current snapshot's model-scoped entries, as rows a caller can override.</summary>
    /// <remarks>
    /// Model-scoped entries only. Every row <see cref="Publish"/> receives is applied at both scopes,
    /// so replaying the model-scoped half rebuilds the provider-wide half exactly - and replaying both
    /// would put two rows for one provider into the same dictionary literal.
    /// </remarks>
    private static IEnumerable<(string ProviderId, string ModelId, AiModelHealthState State)> Rows(
        AiHealthSnapshot snapshot)
        => snapshot.Models.Select(entry =>
            (entry.Key.ProviderId, entry.Key.ModelId, entry.Value));

    /// <summary>Publishes a snapshot built from the caller's rows and nothing else.</summary>
    /// <remarks>
    /// The two absence tests use this, because "a route nobody published is not reachable" cannot be
    /// stated against a snapshot that inherited a row for it.
    /// </remarks>
    private static void PublishExclusively(
        GovernedPath path,
        params (string ProviderId, string ModelId, AiModelHealthState State)[] rows)
    {
        var providers = new Dictionary<string, AiModelHealthState>(StringComparer.Ordinal);
        var models = new Dictionary<(string ModelId, string ProviderId), AiModelHealthState>();

        foreach (var (providerId, modelId, state) in rows)
        {
            providers[providerId] = state;
            models[(modelId, providerId)] = state;
        }

        path.Health.Publish(new AiHealthSnapshot
        {
            TakenAt = DateTimeOffset.UtcNow,
            Source = "w7e-test-sweep",
            Providers = providers,
            Models = models,
        });
    }

    /// <summary>Observed attempts for the fixture's two routes: the primary bad, the alternate good.</summary>
    private static IReadOnlyList<AiReliabilityAttempt> Observed(bool reversed = false)
    {
        var history = new List<AiReliabilityAttempt>();

        history.AddRange(reversed
            ? History(PrimaryProvider, PrimaryModel, succeeded: 4, failed: 0)
            : History(PrimaryProvider, PrimaryModel, succeeded: 0, failed: 4));

        history.AddRange(reversed
            ? History(AlternateProvider, AlternateModel, succeeded: 0, failed: 4)
            : History(AlternateProvider, AlternateModel, succeeded: 4, failed: 0));

        return history;
    }

    /// <summary>A policy that requires evidence, so an unobserved route is refused rather than assumed.</summary>
    private static AiReliabilityPolicy Strict() => new()
    {
        MinimumSampleSize = 2,
        MinimumSuccessRate = 0.5,
        ConsecutiveFailureCeiling = 10,
        RequireEvidence = true,
    };

    /// <summary>A governance policy that refuses nothing, so a routing decision under test is a real one.</summary>
    /// <remarks>
    /// Wired to the registry's own governance register, which is what makes its permissiveness a
    /// statement about the fixture's approvals rather than about a policy that was told to allow. The
    /// budget table is left empty and the coverage requirement off for the reason the W7D harness gives:
    /// these models are unpriced, so the cost dimension is inert and a coverage refusal here would hide
    /// the gate under test behind a different one.
    /// </remarks>
    private static AiGovernancePolicy Permissive(ConfiguredAiRegistry registry) => new()
    {
        Dependencies = AiDependencyRegistry.Empty,
        Capabilities = AiCapabilityRegister.Bootstrap(),
        Exposure = DataExposurePolicy.Default(),
        Register = new RegistryAiGovernanceRegister(registry, registry, registry, registry),
        Budgets = [],
        RequireBudgetRuleForPricedExecution = false,
        Tools = registry.GovernanceRules,
        Escalations = [],
    };

    /// <summary>The fixture's two-route estate as a configuration, for the probe sweep.</summary>
    private static AiRegistryConfiguration TwoRouteConfiguration() => new()
    {
        Provenance = "W7E test fixture.",
        Routing = new AiRoutingConfigurationEntry { Objective = "Balanced", FallbackDepth = 1 },
        Providers = [Route(PrimaryProvider, priority: 10), Route(AlternateProvider, priority: 5)],
        Models = [ModelFor(PrimaryModel, PrimaryProvider), ModelFor(AlternateModel, AlternateProvider)],
        Health =
        [
            new AiHealthConfigurationEntry { ProviderId = PrimaryProvider, State = "Available" },
            new AiHealthConfigurationEntry
            {
                ProviderId = PrimaryProvider,
                ModelId = PrimaryModel,
                State = "Available",
            },
            new AiHealthConfigurationEntry { ProviderId = AlternateProvider, State = "Available" },
            new AiHealthConfigurationEntry
            {
                ProviderId = AlternateProvider,
                ModelId = AlternateModel,
                State = "Available",
            },
        ],
    };
}

/// <summary>A probe that reaches nothing and counts what it was asked about.</summary>
/// <remarks>
/// It handles every target and observes <see cref="AiModelHealthState.Available"/>, which is what makes
/// it a usable instrument: it produces a definite state, so a sweep that reached it changes the
/// published snapshot and a sweep that did not is visible as an unchanged one.
/// </remarks>
internal sealed class CountingProbe : IAiHealthProbe
{
    /// <summary>Every target this probe was asked about, in order.</summary>
    public List<AiHealthProbeTarget> Targets { get; } = [];

    /// <inheritdoc />
    public string ProbeId => "w7e-counting-probe";

    /// <inheritdoc />
    public bool Handles(AiHealthProbeTarget target) => true;

    /// <inheritdoc />
    public ValueTask<AiHealthObservation> ProbeAsync(
        AiHealthProbeTarget target,
        CancellationToken cancellationToken)
    {
        Targets.Add(target);

        return ValueTask.FromResult(AiHealthObservation.Observed(
            target.ProviderId,
            target.ModelId,
            ProbeId,
            DateTimeOffset.UtcNow,
            AiModelHealthState.Available,
            "W7E counting probe: observed without reaching anything."));
    }
}
