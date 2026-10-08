using System.Collections.Generic;
using System.Linq;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Registry;
using Nexus.Intelligence.Core.Routing;
using Xunit;

namespace Nexus.Intelligence.Tests.Routing;

// W7C TASK 9: the router's guards, each paired with a control that produces the opposite result.
//
// WHAT THIS SUITE IS FOR. The directive's exit condition is a list of things that must NEVER happen:
// a blocked provider is never selected, a blocked model is never selected, a fallback can never
// bypass governance, an unhealthy primary falls back only to what is allowed. A test that only
// asserted the happy path would satisfy none of them, and a test that asserted a refusal would pass
// on a router that refuses everything.
//
// So every guard below is asserted in BOTH directions from the same fixture with ONE field changed:
// approved routes and unapproved does not, healthy routes and unhealthy does not. The control is what
// makes the refusal evidence. Where a control is impossible (a fallback cannot be observed to bypass
// governance if no fallback is ever built) the assertion is structural instead - the chain is a slice
// of the governed eligible set - and that is said so in the test rather than left implicit.
public sealed class GovernedCapabilityRouterTests
{
    // The capability the fixture serves, and one nothing in the fixture serves. Both are real
    // members of AiCapabilities, because a capability nobody has ever registered would test the
    // parser rather than the router.
    private const string Served = AiCapabilities.CodeReview;
    private const string Unserved = AiCapabilities.DocumentSummarize;

    // ---------------------------------------------------------------------------------------------
    // 1. A caller requests a CAPABILITY, and never names a provider or a model.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void CapabilityRequest_WithNoProviderNamed_IsRoutedToAnEligibleProvider()
    {
        var providers = new[] { Provider("prov-a") };
        var models = new[] { Model("model-a", "prov-a") };
        var registry = Registry(providers, models, Healthy(models));

        var outcome = Route(registry, Request());

        Assert.True(outcome.IsRouted, outcome.Reason);
        Assert.NotNull(outcome.Selected);
        Assert.Equal("model-a", outcome.Selected!.ModelId);
        Assert.Equal("prov-a", outcome.Selected.ProviderId);

        // The request type cannot carry a provider, so the only way one appears is that the router
        // chose it. This is the directive's "callers request capabilities, not providers" - asserted
        // against the same request object that produced the selection.
        Assert.Null(typeof(AiCapabilityRequest).GetProperty("ProviderId"));
        Assert.Null(typeof(AiCapabilityRequest).GetProperty("ModelId"));
    }

    [Fact]
    public void CapabilityRequest_ForACapabilityNothingServes_IsCapabilityNotFound()
    {
        var models = new[] { Model("model-a", "prov-a") };
        var registry = Registry([Provider("prov-a")], models, Healthy(models));

        var outcome = Route(registry, Request(Unserved));

        // A valid, typed result rather than an exception or a default model - the directive's
        // requirement that CAPABILITY_NOT_FOUND be a legal answer.
        Assert.Equal(AiRoutingStatus.CapabilityNotFound, outcome.Status);
        Assert.Null(outcome.Selected);
        Assert.NotNull(outcome.Failure);
        Assert.Equal(AiFailureCategory.CapabilityNotFound, outcome.Failure!.Category);

        // NON-VACUITY: the same fixture routes the capability it does serve, so the refusal above is
        // the missing capability and not a fixture that cannot route anything.
        Assert.True(Route(registry, Request()).IsRouted);
    }

    // ---------------------------------------------------------------------------------------------
    // 2. A BLOCKED PROVIDER is never selected.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void UnapprovedProvider_IsNeverSelected_AndNeverEntersTheFallbackChain()
    {
        var providers = new[]
        {
            Provider("prov-a"),
            Provider("prov-b", approval: "Suspended"),
        };

        var models = new[] { Model("model-a", "prov-a"), Model("model-b", "prov-b") };
        var registry = Registry(providers, models, Healthy(models));

        var outcome = Route(registry, Request());

        Assert.True(outcome.IsRouted, outcome.Reason);
        Assert.Equal("prov-a", outcome.Selected!.ProviderId);

        // The strong claim, and the reason it is written as a scan rather than as an equality: the
        // blocked provider must not appear ANYWHERE a selection could be taken from. Asserting only
        // on Selected would pass on a router that built a chain containing it.
        Assert.DoesNotContain(outcome.Eligible, c => c.ProviderId == "prov-b");
        Assert.DoesNotContain(outcome.FallbackChain, c => c.ProviderId == "prov-b");

        var refusal = Assert.Single(outcome.Rejected, r => r.ProviderId == "prov-b");
        Assert.Equal(AiRoutingRejectionReason.GovernanceBlocked, refusal.Reason);
        Assert.NotNull(refusal.Governance);

        // NON-VACUITY: approve the same provider and it becomes eligible, so the exclusion was the
        // approval and not an unreachable fixture.
        var approved = Registry(
            [Provider("prov-a"), Provider("prov-b")],
            models,
            Healthy(models));

        var permitted = Route(approved, Request());

        Assert.Contains(permitted.Eligible, c => c.ProviderId == "prov-b");
    }

    // ---------------------------------------------------------------------------------------------
    // 3. A BLOCKED MODEL is never selected.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void UnapprovedModel_IsNeverSelected_AndNeverEntersTheFallbackChain()
    {
        var models = new[]
        {
            Model("model-a", "prov-a"),
            Model("model-b", "prov-a", approval: "Suspended"),
        };

        var registry = Registry([Provider("prov-a")], models, Healthy(models));

        var outcome = Route(registry, Request(), fallbackDepth: 5);

        Assert.True(outcome.IsRouted, outcome.Reason);
        Assert.Equal("model-a", outcome.Selected!.ModelId);
        Assert.DoesNotContain(outcome.Eligible, c => c.ModelId == "model-b");
        Assert.DoesNotContain(outcome.FallbackChain, c => c.ModelId == "model-b");

        var refusal = Assert.Single(outcome.Rejected, r => r.ModelId == "model-b");
        Assert.Equal(AiRoutingRejectionReason.GovernanceBlocked, refusal.Reason);

        // NON-VACUITY: the fallback depth is 5 here and the chain is still empty, because the only
        // other route is blocked. That is the "never fall back to a model governance has blocked"
        // requirement stated as a count.
        Assert.Empty(outcome.FallbackChain);

        // ...and approving it does produce a chain, so the emptiness above was the block.
        var bothApproved = new[] { Model("model-a", "prov-a"), Model("model-b", "prov-a") };
        var approved = Registry([Provider("prov-a")], bothApproved, Healthy(bothApproved));

        Assert.Single(Route(approved, Request(), fallbackDepth: 5).FallbackChain);
    }

    // ---------------------------------------------------------------------------------------------
    // 4. An UNHEALTHY PRIMARY falls back only to an allowed route.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void UnhealthyPrimary_FallsBackOnlyToAHealthyAllowedRoute()
    {
        var providers = new[]
        {
            Provider("prov-a", priority: 30),
            Provider("prov-b", priority: 20),
            Provider("prov-c", priority: 10),
        };

        var models = new[]
        {
            Model("model-a", "prov-a"),
            Model("model-b", "prov-b"),
            Model("model-c", "prov-c", approval: "Suspended"),
        };

        // model-a is the preferred route by operator priority and is DOWN. model-b is the allowed
        // secondary. model-c is present, healthy and reachable, and unapproved.
        var health = Healthy(models).Select(entry =>
            entry.ModelId == "model-a" ? WithState(entry, "Unavailable") : entry).ToArray();

        var registry = Registry(providers, models, health);

        var outcome = Route(registry, Request(), fallbackDepth: 5);

        Assert.True(outcome.IsRouted, outcome.Reason);
        Assert.Equal("model-b", outcome.Selected!.ModelId);

        var downRefusal = Assert.Single(outcome.Rejected, r => r.ModelId == "model-a");
        Assert.Equal(AiRoutingRejectionReason.ModelUnhealthy, downRefusal.Reason);
        Assert.DoesNotContain(outcome.Eligible, c => c.ModelId == "model-c");

        // NON-VACUITY: with model-a healthy it wins on priority, so the fallback above was the health
        // reading and not the ranking.
        var primaryUp = Registry(providers, models, Healthy(models));

        Assert.Equal("model-a", Route(primaryUp, Request(), fallbackDepth: 5).Selected!.ModelId);
    }

    // ---------------------------------------------------------------------------------------------
    // 5. A BUDGET-BLOCKED model is excluded.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ModelAboveTheCallerCostCeiling_IsExcluded()
    {
        var models = new[]
        {
            Model("model-cheap", "prov-a", costIn: 0.001m, costOut: 0.002m, currency: "USD"),
            Model("model-dear", "prov-a", costIn: 0.01m, costOut: 0.02m, currency: "USD"),
        };

        var registry = Registry([Provider("prov-a")], models, Healthy(models));

        var context = new AiRoutingContext { InputTokens = 1_000, OutputTokens = 1_000 };
        var request = Request(maxCost: 0.01m, currency: "USD");

        var outcome = Route(registry, request, fallbackDepth: 5, context: context);

        Assert.True(outcome.IsRouted, outcome.Reason);
        Assert.Equal("model-cheap", outcome.Selected!.ModelId);

        var refusal = Assert.Single(outcome.Rejected, r => r.ModelId == "model-dear");
        Assert.Equal(AiRoutingRejectionReason.CallerCostCeilingExceeded, refusal.Reason);
        Assert.DoesNotContain(outcome.FallbackChain, c => c.ModelId == "model-dear");

        // NON-VACUITY: raise the ceiling and the dear model becomes eligible, so the exclusion was the
        // ceiling and not an unpriced model.
        var raised = Route(
            registry, Request(maxCost: 5m, currency: "USD"), fallbackDepth: 5, context: context);

        Assert.Contains(raised.Eligible, c => c.ModelId == "model-dear");
    }

    [Fact]
    public void UnpricedModelAgainstACallerCeiling_FailsClosed()
    {
        // No rates declared, so no prediction is possible. The gate refuses rather than treating an
        // unknown cost as free - a ceiling that could be satisfied by not knowing the price would be
        // satisfied by never recording one.
        var models = new[] { Model("model-unpriced", "prov-a") };
        var registry = Registry([Provider("prov-a")], models, Healthy(models));

        var context = new AiRoutingContext { InputTokens = 1_000, OutputTokens = 1_000 };
        var outcome = Route(registry, Request(maxCost: 1m, currency: "USD"), context: context);

        Assert.Equal(AiRoutingStatus.NoEligibleModel, outcome.Status);
        Assert.Equal(
            AiRoutingRejectionReason.CostUnknownAgainstCallerCeiling,
            Assert.Single(outcome.Rejected).Reason);

        // NON-VACUITY: the identical unpriced model routes when the caller sets no ceiling, so the
        // refusal above is the ceiling's effect and not a registry that cannot price it at all.
        Assert.True(Route(registry, Request(), context: context).IsRouted);
    }

    // ---------------------------------------------------------------------------------------------
    // 6. A DISABLED provider, and a disabled model, cannot route.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void DisabledProvider_CannotRoute()
    {
        var models = new[] { Model("model-a", "prov-a") };

        var disabled = Registry([Provider("prov-a", enabled: false)], models, Healthy(models));

        var refused = Route(disabled, Request());

        Assert.Equal(AiRoutingStatus.NoEligibleModel, refused.Status);
        Assert.Null(refused.Selected);
        Assert.Equal(
            AiRoutingRejectionReason.ProviderDisabled,
            Assert.Single(refused.Rejected).Reason);

        // NON-VACUITY: enabling the provider - the only change - routes the same request.
        var enabled = Registry([Provider("prov-a")], models, Healthy(models));

        Assert.True(Route(enabled, Request()).IsRouted);
    }

    [Fact]
    public void DisabledModel_CannotRoute()
    {
        var models = new[] { Model("model-a", "prov-a", enabled: false) };
        var disabled = Registry([Provider("prov-a")], models, Healthy(models));

        var refused = Route(disabled, Request());

        Assert.Equal(AiRoutingStatus.NoEligibleModel, refused.Status);
        Assert.Equal(AiRoutingRejectionReason.ModelDisabled, Assert.Single(refused.Rejected).Reason);

        var enabled = Registry([Provider("prov-a")], [Model("model-a", "prov-a")],
            Healthy([Model("model-a", "prov-a")]));

        Assert.True(Route(enabled, Request()).IsRouted);
    }

    // ---------------------------------------------------------------------------------------------
    // 7. An UNREGISTERED provider or model refuses.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ModelNamingAnUnregisteredProvider_IsRefusedByThatName()
    {
        // The model is registered and its provider is not. The registry deliberately does not refuse
        // this at load - the router reports it per route - so this asserts the report.
        var models = new[] { Model("model-orphan", "prov-missing") };
        var registry = Registry([], models, Healthy(models));

        var outcome = Route(registry, Request());

        Assert.Equal(AiRoutingStatus.NoEligibleModel, outcome.Status);
        Assert.Equal(
            AiRoutingRejectionReason.ProviderNotRegistered,
            Assert.Single(outcome.Rejected).Reason);

        // NON-VACUITY: register the missing provider and the same model routes.
        var whole = Registry([Provider("prov-missing")], models, Healthy(models));

        Assert.True(Route(whole, Request()).IsRouted);
    }

    [Fact]
    public void ModelAbsentFromTheGovernanceRegister_IsRefusedAsUnregistered()
    {
        // The registry is empty, so the governance register resolves nothing and every named resource
        // is refused. This is the W7B rule reached through W7C's registry-backed register.
        var registry = Registry([], []);
        var policy = Policy(new RegistryAiGovernanceRegister(registry, registry));

        var decision = new DeterministicAiGovernanceEvaluator(policy).Evaluate(
            new AiGovernanceEvaluationRequest
            {
                RequestId = "req-unregistered",
                Capability = CapabilityId.Parse(Served),
                Requester = Requester(),
                Classification = DataClassification.Public,
                Execution = AiExecutionPolicy.Default,
                Tools = ToolPermissionProfile.None,
                ModelId = "model-nowhere",
                ProviderId = "prov-nowhere",
                CorrelationId = "corr-unregistered",
            },
            AiPlatformGovernanceAttestation.NotApplicable);

        Assert.True(decision.IsBlocked, decision.Reason);
        Assert.Equal(AiGovernanceRules.ModelUnregistered, decision.RuleId);
    }

    // ---------------------------------------------------------------------------------------------
    // 8. A FALLBACK CANNOT BYPASS GOVERNANCE.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void EveryRouteInTheChain_IsIndividuallyGoverned()
    {
        // The structural claim, asserted as a property of the produced value rather than by observing
        // a failover: the chain is a slice of the governed eligible set, and every member of that set
        // carries an allowing decision evaluated for THIS request. A route cannot be in the chain
        // without having been through governance, because there is no other source of chain members.
        var providers = new[] { Provider("prov-a"), Provider("prov-b"), Provider("prov-c") };
        var models = new[]
        {
            Model("model-a", "prov-a"),
            Model("model-b", "prov-b"),
            Model("model-c", "prov-c"),
        };

        var registry = Registry(providers, models, Healthy(models));
        var outcome = Route(registry, Request(), fallbackDepth: 5);

        Assert.True(outcome.IsRouted, outcome.Reason);
        Assert.Equal(2, outcome.FallbackChain.Count);

        Assert.All(outcome.Eligible, candidate =>
            Assert.True(candidate.Governance.IsAllowed, $"{candidate.ModelId} is eligible without an allowing decision."));

        Assert.All(outcome.FallbackChain, candidate =>
            Assert.True(candidate.Governance.IsAllowed, $"{candidate.ModelId} is in the chain without an allowing decision."));

        // And every chain member is genuinely one of the eligible routes, not a parallel list.
        Assert.All(outcome.FallbackChain, candidate => Assert.Contains(candidate, outcome.Eligible));
    }

    [Fact]
    public void RequestScopedRefusal_IsTerminal_EvenThoughAPermittedRouteExists()
    {
        // The hardest form of "fallback cannot bypass governance": a refusal that is a property of the
        // REQUEST rather than of any route. A perfect model is registered, approved, enabled, healthy
        // and serving the capability - and the request is still refused, because escalating to a
        // different model is not an answer to a question a human was asked.
        var models = new[] { Model("model-a", "prov-a") };
        var registry = Registry([Provider("prov-a")], models, Healthy(models));

        var escalation = new AiGovernanceEscalationRule
        {
            RuleId = "test.escalation.cost",
            Subject = AiGovernanceSubject.Cost,
            Capability = CapabilityId.Parse(Served),
            Reason = "Spend on this capability is reviewed by a person.",
        };

        var policy = Policy(
            new RegistryAiGovernanceRegister(registry, registry),
            escalations: [escalation]);

        var outcome = new GovernedCapabilityRouter(
            registry, registry, registry,
            new DeterministicAiGovernanceEvaluator(policy),
            Operational(registry),
            new AiRoutingPolicy { FallbackDepth = 5 },
            TimeProvider.System)
            .Route(Request(), AiPlatformGovernanceAttestation.NotApplicable, AiRoutingContext.Unstated);

        Assert.Equal(AiRoutingStatus.HumanDecisionRequired, outcome.Status);
        Assert.Null(outcome.Selected);

        // Nothing to fall back TO. An empty eligible set is the structural guarantee: a failover
        // walking the chain walks nothing, so it cannot reach the model that a route-scoped check
        // would have permitted.
        Assert.Empty(outcome.Eligible);
        Assert.Empty(outcome.FallbackChain);
        Assert.True(outcome.RequiresHumanDecision);

        // NON-VACUITY: remove the escalation - the only change - and the identical fixture routes.
        var unescalated = Policy(new RegistryAiGovernanceRegister(registry, registry));

        Assert.True(new GovernedCapabilityRouter(
            registry, registry, registry,
            new DeterministicAiGovernanceEvaluator(unescalated),
            Operational(registry),
            new AiRoutingPolicy { FallbackDepth = 5 },
            TimeProvider.System)
            .Route(Request(), AiPlatformGovernanceAttestation.NotApplicable, AiRoutingContext.Unstated)
            .IsRouted);
    }

    [Fact]
    public void GovernanceRefusal_ReportsGovernanceBlocked_NotAnEmptyInventory()
    {
        // Every route refused by POLICY must not be reported as "nothing serves this". The two have
        // different remedies and an operator who cannot tell them apart looks in the wrong place.
        var models = new[]
        {
            Model("model-a", "prov-a", approval: "Suspended"),
            Model("model-b", "prov-b", approval: "Retired"),
        };

        var registry = Registry([Provider("prov-a"), Provider("prov-b")], models, Healthy(models));
        var outcome = Route(registry, Request());

        Assert.Equal(AiRoutingStatus.GovernanceBlocked, outcome.Status);
        Assert.Null(outcome.Selected);

        // Both refusals survive, so the outcome names every rule that refused a route.
        Assert.Equal(2, outcome.Rejected.Count);
        Assert.All(outcome.Rejected, r => Assert.Equal(AiRoutingRejectionReason.GovernanceBlocked, r.Reason));
    }

    [Fact]
    public void PlatformRefusal_MakesEveryRouteUnroutable()
    {
        // Platform Governance is deterministic and non-AI, and AI Governance may not override it. The
        // attestation is carried into every evaluation, so a platform refusal reaches both passes.
        var models = new[] { Model("model-a", "prov-a") };
        var registry = Registry([Provider("prov-a")], models, Healthy(models));

        var outcome = new GovernedCapabilityRouter(
            registry, registry, registry,
            new DeterministicAiGovernanceEvaluator(Policy(new RegistryAiGovernanceRegister(registry, registry))),
            Operational(registry),
            AiRoutingPolicy.Default,
            TimeProvider.System)
            .Route(
                Request(),
                AiPlatformGovernanceAttestation.Refuse(AiGovernanceAuthority.Deployment, "The window is closed."),
                AiRoutingContext.Unstated);

        Assert.False(outcome.IsRouted);
        Assert.Equal(AiRoutingStatus.GovernanceBlocked, outcome.Status);
        Assert.Equal(AiGovernanceRules.PlatformAuthorityRefused, outcome.Governance.RuleId);
    }

    // ---------------------------------------------------------------------------------------------
    // 11. The guards can fail: the same fixture, one field changed, opposite outcome.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheGovernanceGuard_IsNotVacuous_ApprovalAloneChangesTheOutcome()
    {
        // One fixture, two compositions, one field different. If the router refused everything, the
        // approved half fails; if it permitted everything, the unapproved half fails. Neither can pass
        // by being unable to see anything.
        var unapproved = new[] { Model("model-a", "prov-a", approval: "Unregistered") };
        var approved = new[] { Model("model-a", "prov-a") };

        var refused = Route(
            Registry([Provider("prov-a")], unapproved, Healthy(unapproved)), Request());

        var routed = Route(
            Registry([Provider("prov-a")], approved, Healthy(approved)), Request());

        Assert.Equal(AiRoutingStatus.GovernanceBlocked, refused.Status);
        Assert.True(routed.IsRouted, routed.Reason);
        Assert.Equal("model-a", routed.Selected!.ModelId);
    }

    [Fact]
    public void TheHealthGuard_IsNotVacuous_HealthAloneChangesTheOutcome()
    {
        var models = new[] { Model("model-a", "prov-a") };

        var down = Route(
            Registry([Provider("prov-a")], models, Healthy(models, state: "Unavailable")), Request());

        var up = Route(Registry([Provider("prov-a")], models, Healthy(models)), Request());

        Assert.Equal(AiRoutingStatus.NoEligibleModel, down.Status);
        Assert.Equal(AiRoutingRejectionReason.ModelUnhealthy, Assert.Single(down.Rejected).Reason);
        Assert.True(up.IsRouted, up.Reason);
    }

    [Fact]
    public void TheFallbackCannotBypassGovernance_EvenWhenDepthsAllowIt()
    {
        // A large fallback depth over a registry containing an unapproved route. The depth is not a
        // permission: it bounds how far a failover may walk, it does not widen what it may walk onto.
        var models = new[]
        {
            Model("model-a", "prov-a", enabled: false),
            Model("model-b", "prov-a", approval: "Suspended"),
            Model("model-c", "prov-a"),
        };

        var registry = Registry([Provider("prov-a")], models, Healthy(models));
        var outcome = Route(registry, Request(), fallbackDepth: 10);

        Assert.True(outcome.IsRouted, outcome.Reason);
        Assert.Equal("model-c", outcome.Selected!.ModelId);
        Assert.Empty(outcome.FallbackChain);

        // The disabled and the unapproved route are both named, so the operator sees why the chain is
        // empty rather than inferring it.
        Assert.Contains(outcome.Rejected, r => r.ModelId == "model-a" && r.Reason == AiRoutingRejectionReason.ModelDisabled);
        Assert.Contains(outcome.Rejected, r => r.ModelId == "model-b" && r.Reason == AiRoutingRejectionReason.GovernanceBlocked);
    }

    // ---------------------------------------------------------------------------------------------
    // Routing strategy is a preference over permitted routes, and can never widen them.
    // ---------------------------------------------------------------------------------------------

    [Theory]
    [InlineData("CheapestEligible")]
    [InlineData("HighestReliability")]
    [InlineData("HighestReasoning")]
    [InlineData("ConfiguredOrder")]
    [InlineData("Balanced")]
    public void EveryObjective_PermitsExactlyTheSameSet(string objective)
    {
        // The objective changes the ORDER, never the SET. A misconfigured policy must be able to
        // produce a suboptimal route and never an ungoverned one - which is what makes it safe to
        // expose as configuration at all.
        var models = new[]
        {
            Model("model-a", "prov-a", costIn: 0.001m, costOut: 0.001m, currency: "USD"),
            Model("model-b", "prov-b", costIn: 0.02m, costOut: 0.02m, currency: "USD", reasoning: "Low"),
            Model("model-blocked", "prov-b", approval: "Suspended"),
        };

        var registry = Registry(
            [Provider("prov-a", priority: 10), Provider("prov-b", priority: 20)],
            models,
            Healthy(models),
            objective: objective,
            fallbackDepth: 5);

        var outcome = Route(registry, Request());

        Assert.True(outcome.IsRouted, outcome.Reason);
        Assert.Equal(2, outcome.Eligible.Count);
        Assert.DoesNotContain(outcome.Eligible, c => c.ModelId == "model-blocked");
        Assert.All(outcome.Eligible, c => Assert.True(c.Governance.IsAllowed));
    }

    [Fact]
    public void UnknownObjective_IsRefusedAtComposition()
    {
        // A name that is not a member.
        Assert.Throws<InvalidOperationException>(() => AiRoutingPolicy.From(
            new AiRoutingConfigurationEntry { Objective = "Cheapest" }));

        // A NUMERAL THAT NAMES A REAL MEMBER. AiRoutingObjective.CheapestEligible is 1, so
        // Enum.TryParse("1") succeeds and Enum.IsDefined(1) is true - the obvious strict parse accepts
        // this and the estate silently runs CheapestEligible because a configuration typo'd a 1. The
        // name-only parse refuses it, which is what makes renumbering a member unable to change what a
        // deployed file means.
        Assert.Throws<InvalidOperationException>(() => AiRoutingPolicy.From(
            new AiRoutingConfigurationEntry { Objective = "1" }));

        // CONTROL: a known objective parses, case-insensitively, so the refusals above are the
        // validation and not a parser that rejects everything.
        Assert.Equal(
            AiRoutingObjective.CheapestReliable,
            AiRoutingPolicy.From(new AiRoutingConfigurationEntry { Objective = "cheapestreliable" }).Objective);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    private static AiRoutingOutcome Route(
        ConfiguredAiRegistry registry,
        AiCapabilityRequest request,
        int fallbackDepth = 1,
        AiRoutingContext? context = null) => new GovernedCapabilityRouter(
            registry,
            registry,
            registry,
            new DeterministicAiGovernanceEvaluator(
                Policy(new RegistryAiGovernanceRegister(registry, registry))),
            Operational(registry),
            new AiRoutingPolicy { FallbackDepth = fallbackDepth },
            TimeProvider.System)
            .Route(
                request,
                AiPlatformGovernanceAttestation.NotApplicable,
                context ?? AiRoutingContext.Unstated);

    /// <summary>
    /// The operational gate W7E added to the router, configured here to permit everything.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>The real gate, not a double.</b> This suite is a W7C regression run: it has to keep proving
    /// what it names, and a stub gate that returned "eligible" would make its green a statement about
    /// the stub. The real one is used, wired to the registry's own rates, and it permits every route
    /// here because the policies it reads say so — an unevaluated budget policy and the shipped
    /// reliability policy, whose <c>RequireEvidence</c> default is false.
    /// </para>
    /// <para>
    /// <b>What that means for these tests.</b> Nothing in this file changes behaviour because of W7E:
    /// the budget gate has no ceiling to compare against and the reliability gate has no evidence to
    /// find, so both allow. A W7C test that passed before this lane passes for the same reason after
    /// it, and the W7E suite is where the gate is configured to refuse.
    /// </para>
    /// </remarks>
    private static GovernedAiOperationalEligibility Operational(ConfiguredAiRegistry registry)
    {
        var reliabilityPolicy = AiReliabilityPolicy.Default;
        var circuitPolicy = AiCircuitPolicy.Default;
        var history = new InMemoryAiReliabilityHistory(TimeProvider.System);

        return new(
            new ConfiguredAiPriceCatalogue(registry),
            new ConfiguredAiBudgetEvaluator(AiOperationsBudgetPolicy.NotEvaluated),
            history,
            reliabilityPolicy,
            new ReplayedAiCircuitBreaker(history, reliabilityPolicy, circuitPolicy),
            circuitPolicy);
    }

    private static AiGovernancePolicy Policy(
        IAiGovernanceRegister register,
        IReadOnlyList<AiGovernanceEscalationRule>? escalations = null) => new()
        {
            Dependencies = AiDependencyRegistry.Empty,
            Capabilities = AiCapabilityRegister.Bootstrap(),
            Exposure = DataExposurePolicy.Default(),
            Register = register,
            Budgets = [],

            // No budget rules. The router's own caller-ceiling gate is what these tests exercise, and
            // the governance budget dimension is W7B's, already covered by its own suite. Leaving the
            // requirement on would make every priced route refuse for lack of a rule and hide the gate
            // under test behind a different refusal.
            RequireBudgetRuleForPricedExecution = false,

            Tools = [],
            Escalations = escalations ?? [],
        };

    private static ConfiguredAiRegistry Registry(
        IEnumerable<AiProviderConfigurationEntry> providers,
        IEnumerable<AiModelConfigurationEntry> models,
        IEnumerable<AiHealthConfigurationEntry>? health = null,
        string objective = "Balanced",
        int fallbackDepth = 1) => new(new AiRegistryConfiguration
        {
            Provenance = "W7C test fixture.",
            Routing = new AiRoutingConfigurationEntry { Objective = objective, FallbackDepth = fallbackDepth },
            Providers = [.. providers],
            Models = [.. models],
            Health = [.. health ?? []],
        });

    private static AiProviderConfigurationEntry Provider(
        string id,
        bool enabled = true,
        bool egress = false,
        string trust = "Approved",
        string approval = "Approved",
        int priority = 0) => new()
        {
            ProviderId = id,
            DisplayName = id,
            AdapterIdentity = "Nexus.Intelligence.Tests.Adapter",
            Capabilities = [Served, AiCapabilities.ChatComplete],
            Enabled = enabled,

            // The approved reference NAME. Never a value: no test in this suite has one to give, and
            // the registry refuses anything that is not shaped like a name.
            SecretReference = "NEXUS_TEST_API_KEY",
            PermitsRemoteEgress = egress,
            Trust = trust,
            Priority = priority,
            Weight = 1.0,
            Approval = approval,
            MaxClassification = "Public",
            ApprovedBy = approval == "Approved" ? "test-owner" : null,
            GovernanceRationale = "W7C test fixture.",
        };

    private static AiModelConfigurationEntry Model(
        string id,
        string providerId,
        bool enabled = true,
        string availability = "Available",
        string approval = "Approved",
        string reasoning = "High",
        decimal? costIn = null,
        decimal? costOut = null,
        string? currency = null,
        IReadOnlyList<string>? capabilities = null) => new()
        {
            ModelId = id,
            ProviderId = providerId,
            DisplayName = id,
            Capabilities = capabilities is null
                ? [Served, AiCapabilities.ChatComplete]
                : [.. capabilities],
            MaxContextTokens = 200_000,
            MaxOutputTokens = 8_192,
            InputModalities = ["Text"],
            OutputModalities = ["Text"],
            Reasoning = reasoning,
            RelativeSpeed = "Normal",
            Availability = availability,
            Enabled = enabled,
            CostMetadataReference = costIn is null ? null : id,
            InputCostPer1kTokens = costIn,
            OutputCostPer1kTokens = costOut,
            CostCurrency = currency,
            Approval = approval,
            MaxClassification = "Public",
            ApprovedBy = approval == "Approved" ? "test-owner" : null,
            GovernanceRationale = "W7C test fixture.",
        };

    /// <summary>
    /// Health for every model and every provider it names, so a route is routable unless a test says
    /// otherwise. Both entries are needed: a model's health does not fall back to its provider's.
    /// </summary>
    private static IReadOnlyList<AiHealthConfigurationEntry> Healthy(
        IEnumerable<AiModelConfigurationEntry> models,
        string state = "Available")
    {
        var entries = new List<AiHealthConfigurationEntry>();

        foreach (var providerId in models.Select(m => m.ProviderId).Distinct(StringComparer.Ordinal))
        {
            entries.Add(new AiHealthConfigurationEntry { ProviderId = providerId, State = state });
        }

        foreach (var model in models)
        {
            entries.Add(new AiHealthConfigurationEntry
            {
                ProviderId = model.ProviderId,
                ModelId = model.ModelId,
                State = state,
            });
        }

        return entries;
    }

    private static AiHealthConfigurationEntry WithState(AiHealthConfigurationEntry entry, string state)
        => new() { ProviderId = entry.ProviderId, ModelId = entry.ModelId, State = state };

    private static AiCapabilityRequest Request(
        string capability = Served,
        decimal? maxCost = null,
        string? currency = null) => new()
        {
            RequestId = "req-w7c",
            Capability = CapabilityId.Parse(capability),
            Purpose = "Exercise the W7C router.",
            Requester = Requester(),
            Input = new TurnInput(TurnInputKind.Task, "review this", []),
            Classification = DataClassification.Public,
            Execution = maxCost is null
                ? AiExecutionPolicy.Default
                : AiExecutionPolicy.Default with { MaxCost = maxCost, CostCurrency = currency },
            IdempotencyKey = "idem-w7c",
        };

    private static AiRequesterIdentity Requester() => new()
    {
        Head = CallingHead.Ai,
        PrincipalId = "principal-w7c",
        PermissionScope = AiPermissionScope.None,
        DataScopes = [],
    };
}
