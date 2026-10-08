using System.Collections.Generic;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Registry;
using Nexus.Intelligence.Core.Turns;
using Nexus.Intelligence.Tests.Turns;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Tests.Operations;

// The W7E operational fixtures. Every one of them composes a REAL governed path through
// GovernedPath.Compose, so a test written against these helpers is a statement about the estate's own
// ledger, gate, selector and recorder — not about a stand-in for them.
//
// WHY A TWO-ROUTE ESTATE. Most of W7E's claims are about what happens when a route fails: it must be
// skipped, and the fallback must be selected without bypassing governance. Neither is observable in a
// single-route fixture, so the default shape here is two providers each serving one model.
//
// WHY THE PRIMARY IS THE ONE IT IS. The router's ranking is deterministic and its tie-breakers are
// explicit: score, then provider priority, then model identifier ordinally. The two routes below are
// otherwise identical, so the higher priority wins and `Primary*` is provably the primary rather than
// assumed to be.
internal static class W7eFixture
{
    /// <summary>The provider the ranking should prefer. Higher priority than the alternate.</summary>
    public const string PrimaryProvider = "prov-a";

    /// <summary>The primary's model.</summary>
    public const string PrimaryModel = "prov-a:model-a";

    /// <summary>The provider a failover should reach.</summary>
    public const string AlternateProvider = "prov-b";

    /// <summary>The alternate's model.</summary>
    public const string AlternateModel = "prov-b:model-b";

    /// <summary>Executes one turn through the composed path with the fixture's standard request.</summary>
    public static GovernedTurnOutcome Run(GovernedPath path)
        => Run(path, GovernedPath.Turn(path.Options));

    /// <summary>Executes one turn under a caller-named request identifier.</summary>
    /// <remarks>
    /// <b>W7F TASK 2 changed what this helper is for, and the comment here said the opposite until it
    /// did.</b> It used to read that two distinct executions on one composed path required two distinct
    /// request identifiers, because the execution identity was the request identifier. That is no longer
    /// true: each execution mints its own identity, so two executions under one request identifier are
    /// two records. Naming the identifier is now how a test states what the CALLER did — replaying, or
    /// asking something new — and the execution identity is asserted separately rather than implied.
    /// </remarks>
    public static GovernedTurnOutcome Run(GovernedPath path, string requestId)
        => Run(path, GovernedPath.Turn(path.Options, requestId: requestId));

    /// <summary>Executes an already-built turn through the composed path.</summary>
    /// <remarks>
    /// <b>The one place a W7E test waits on the governed path synchronously.</b> Every fixture runs
    /// through here rather than calling <c>GetAwaiter().GetResult()</c> at the assertion site, so the
    /// estate has a single blocking call to reason about and the test methods themselves hold no
    /// blocking wait. A test that needs a shape this does not cover — a caller-supplied context, say —
    /// builds the turn and hands it here rather than reaching past the fixture.
    /// </remarks>
    public static GovernedTurnOutcome Run(GovernedPath path, GovernedTurnRequest request)
        => path.ExecuteAsync(request).GetAwaiter().GetResult();

    /// <summary>
    /// A capability request of the same shape the router and the failover selector are handed.
    /// </summary>
    /// <remarks>
    /// Deliberately the semantic request rather than the turn request: it is the shape that carries the
    /// requester identity and scope the operational gates are evaluated against, so a test that reaches
    /// a gate directly reaches it with the same inputs the governed path would supply.
    /// </remarks>
    public static AiCapabilityRequest Request(string requestId = "req-w7e") => new()
    {
        RequestId = requestId,
        Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
        Purpose = "Exercise one W7E operational stage.",
        Requester = Requester(),
        Input = new TurnInput(TurnInputKind.Task, "summarise the fixture", []),
        Classification = DataClassification.Public,
        Execution = AiExecutionPolicy.Default,
        IdempotencyKey = $"idem-{requestId}",
    };

    /// <summary>The requester identity the fixture's requests carry.</summary>
    /// <remarks>
    /// Delegated to the governed-path fixture rather than restated, so a direct call to an operational
    /// gate and a full turn are evaluated against the same principal, tenant, product and scopes. A
    /// second copy here would drift, and the drift would show up as a gate behaving differently
    /// depending on which fixture reached it.
    /// </remarks>
    public static AiRequesterIdentity Requester() => GovernedPath.Requester();

    /// <summary>
    /// The failover selector, wired exactly as the governed path wires it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The real selector over the real operational gate, reading the same snapshot store and the same
    /// registries the composed path uses. A test that reaches it directly is a statement about the
    /// estate's selector, and it is the only way to hand the selector a failure category the recording
    /// model seam cannot produce.
    /// </para>
    /// <para>
    /// <b>W7G-R added <paramref name="budget"/> and <paramref name="reliability"/>, and the reason is
    /// the selector's own stated purpose.</b> It re-reads the operational gates because "a chain
    /// computed before the first attempt is already stale by the time the first attempt fails". A test
    /// can only exercise that staleness if it can present the selector with a posture the router did not
    /// build the chain under — a ceiling tightened after routing, a route that stopped answering — and
    /// the alternative would be a fixture in which re-evaluation can never differ from the first
    /// evaluation, which is a fixture in which the re-evaluation is untested. Both parameters default to
    /// what the composition root would have used, so a test that names neither is unchanged.
    /// </para>
    /// </remarks>
    public static GovernedAiFailoverSelector Selector(
        GovernedPath path,
        AiOperationsBudgetPolicy? budget = null,
        AiReliabilityPolicy? reliability = null)
    {
        var reliabilityPolicy = reliability ?? AiReliabilityPolicy.Default;
        var circuitPolicy = AiCircuitPolicy.Default;

        return new(
            new GovernedAiOperationalEligibility(
                new ConfiguredAiPriceCatalogue(path.Registry),
                new ConfiguredAiBudgetEvaluator(budget ?? AiOperationsBudgetPolicy.NotEvaluated, path.Ledger),
                path.Reliability,
                reliabilityPolicy,
                new ReplayedAiCircuitBreaker(path.Reliability, reliabilityPolicy, circuitPolicy),
                circuitPolicy),
            new SnapshotAiHealthSource(path.Health),
            path.Registry,
            path.Registry);
    }

    /// <summary>An operational failure to fail over from, of the category a test names.</summary>
    /// <remarks>
    /// <see cref="AiFailureCategory.ProviderUnavailable"/> by default, because that is the failure the
    /// recording model seam actually produces and therefore the one a failover test is describing. A
    /// test passing a governance category is asserting the selector stops.
    /// </remarks>
    public static AiFailure Failure(AiFailureCategory category = AiFailureCategory.ProviderUnavailable)
        => AiFailure.From(category, $"w7e.{category}".ToLowerInvariant(), "W7E test fixture.", "corr-w7e");

    /// <summary>True when the turn reached a provider and the provider reported success.</summary>
    /// <remarks>
    /// The refusal paths leave <see cref="GovernedTurnOutcome.Result"/> null, so a test that asserted
    /// on it directly would be asserting on a null dereference rather than on the estate's behaviour.
    /// </remarks>
    public static bool Succeeded(GovernedTurnOutcome outcome)
        => outcome.Result?.Result.Success is true;

    // ---------------------------------------------------------------------------------------------
    // Estate shapes.
    // ---------------------------------------------------------------------------------------------

    /// <summary>Two providers, two models, both healthy, neither priced.</summary>
    /// <remarks>
    /// <c>providerApproval</c> applies to BOTH routes, because the claim it supports is about an estate
    /// where nothing may run; a fixture needing one route suspended and the other approved states its
    /// own providers instead, so the asymmetry is visible where it is asserted.
    /// </remarks>
    public static GovernedPathOptions TwoRoutes(
        IReadOnlyList<AiHealthConfigurationEntry>? health = null,
        AiOperationsBudgetPolicy? budget = null,
        AiReliabilityPolicy? reliability = null,
        IReadOnlyList<AiReliabilityAttempt>? history = null,
        IReadOnlyList<string>? failingModels = null,
        int fallbackDepth = 1,
        int tokensIn = 0,
        int tokensOut = 0,
        string providerApproval = "Approved",
        string modelApproval = "Approved",
        TimeProvider? time = null) => new()
        {
            Time = time ?? TimeProvider.System,
            Providers =
            [
                Route(PrimaryProvider, priority: 10, approval: providerApproval),
                Route(AlternateProvider, priority: 5, approval: providerApproval),
            ],
            Models =
            [
                ModelFor(PrimaryModel, PrimaryProvider, approval: modelApproval),
                ModelFor(AlternateModel, AlternateProvider, approval: modelApproval),
            ],
            Health = [.. health ?? []],
            Budget = budget,
            Reliability = reliability,
            History = [.. history ?? []],
            FailingModels = [.. failingModels ?? []],
            FallbackDepth = fallbackDepth,
            TokensIn = tokensIn,
            TokensOut = tokensOut,
        };

    /// <summary>Two routes whose primary states rates, so the cost dimension is live.</summary>
    /// <remarks>
    /// <para>
    /// The alternate is deliberately left unpriced. A failover test that priced both would have two
    /// cost projections to reason about, and the claim being made is about routing, not about money.
    /// </para>
    /// <para>
    /// <b>This shape is why the budget-refusal tests below use <see cref="PricedSole"/> instead.</b> The
    /// budget gate has nothing to say about an execution it cannot price, so a ceiling that refuses the
    /// priced route leaves this fixture free to route to the unpriced one — which is correct and is
    /// asserted in its own test, but would make a "the ceiling refused this execution" test pass or fail
    /// for a reason it did not name.
    /// </para>
    /// </remarks>
    public static GovernedPathOptions Priced(
        int tokensIn = 1_000,
        int tokensOut = 1_000,
        AiOperationsBudgetPolicy? budget = null) => new()
        {
            Providers = [Route(PrimaryProvider, priority: 10), Route(AlternateProvider, priority: 5)],
            Models =
            [
                ModelFor(PrimaryModel, PrimaryProvider, inputRate: 0.50m, outputRate: 1.50m),
                ModelFor(AlternateModel, AlternateProvider),
            ],
            Budget = budget,
            TokensIn = tokensIn,
            TokensOut = tokensOut,
        };

    /// <summary>Two routes, both priced, so the cost dimension is live on the fallback as well.</summary>
    /// <remarks>
    /// <para>
    /// <b>W7G-R added this because <see cref="Priced"/> prices only the primary, and that makes the
    /// alternate's budget decision unobservable.</b> An unpriced route is not a free route — it is a
    /// route the budget gate has nothing to compare — so a ceiling can never refuse it through the
    /// ceiling comparison. Every "the fallback was refused on cost" claim therefore needs a fallback
    /// that has a price, which is the one thing <see cref="Priced"/> deliberately withholds.
    /// </para>
    /// <para>
    /// The two rates are chosen so the arithmetic is checkable at a glance: one thousand in and one
    /// thousand out is 1.60 on the primary (0.40 + 1.20) and 2.00 on the alternate (0.50 + 1.50). A
    /// test asserts those figures rather than a tolerance, because a cost claim that cannot be stated
    /// exactly is not a cost claim.
    /// </para>
    /// <para>
    /// <b>The primary is deliberately the CHEAPER of the two, and that is load-bearing rather than
    /// incidental.</b> The router's score includes the cost term <c>1 - cost/maxCost</c>, so pricing a
    /// fallback below its primary makes the fallback outrank it and the "alternate" is then selected
    /// first — the chain inverts and a failover test silently becomes a test of a healthy primary.
    /// Pricing the alternate above the primary keeps the ranking decided by the priority the fixture
    /// already relies on, which is also the shape a real estate has: the route held in reserve costs
    /// more than the one it is reserving.
    /// </para>
    /// </remarks>
    public static GovernedPathOptions PricedBoth(
        int tokensIn = 1_000,
        int tokensOut = 1_000,
        AiOperationsBudgetPolicy? budget = null,
        IReadOnlyList<string>? failingModels = null,
        int fallbackDepth = 1,
        AiReliabilityPolicy? reliability = null,
        IReadOnlyList<AiReliabilityAttempt>? history = null) => new()
        {
            Providers = [Route(PrimaryProvider, priority: 10), Route(AlternateProvider, priority: 5)],
            Models =
            [
                ModelFor(PrimaryModel, PrimaryProvider, inputRate: 0.40m, outputRate: 1.20m),
                ModelFor(AlternateModel, AlternateProvider, inputRate: 0.50m, outputRate: 1.50m),
            ],
            Budget = budget,
            Reliability = reliability,
            History = [.. history ?? []],
            FailingModels = [.. failingModels ?? []],
            FallbackDepth = fallbackDepth,
            TokensIn = tokensIn,
            TokensOut = tokensOut,
        };

    /// <summary>One priced route and nothing else, so a budget refusal has nowhere to route around to.</summary>
    /// <remarks>
    /// W7G.1 adds <paramref name="failingClassification"/> for the same reason this helper is a sole
    /// route at all: a classified provider failure is only observable at the caller when there is no
    /// alternate to absorb it, so Gate 7's proof needs an estate where the failing route is the whole
    /// chain rather than half of one.
    /// </remarks>
    public static GovernedPathOptions PricedSole(
        AiOperationsBudgetPolicy? budget = null,
        int tokensIn = 1_000,
        int tokensOut = 1_000,
        IReadOnlyList<string>? failingModels = null,
        ModelFailureKind? failingClassification = null) => new()
        {
            Providers = [Route(PrimaryProvider, priority: 10)],
            Models = [ModelFor(PrimaryModel, PrimaryProvider, inputRate: 0.50m, outputRate: 1.50m)],
            Budget = budget,
            TokensIn = tokensIn,
            TokensOut = tokensOut,
            FailingModels = [.. failingModels ?? []],
            FailingClassification = failingClassification,
        };

    /// <summary>One unpriced route and nothing else, for the cost gate's boundary.</summary>
    public static GovernedPathOptions UnpricedSole(AiOperationsBudgetPolicy? budget = null) => new()
        {
            Providers = [Route(PrimaryProvider, priority: 10)],
            Models = [ModelFor(PrimaryModel, PrimaryProvider)],
            Budget = budget,
        };

    // ---------------------------------------------------------------------------------------------
    // Individual rows.
    // ---------------------------------------------------------------------------------------------

    /// <summary>One provider. Priority is the fixture's only lever on the ranking.</summary>
    public static AiProviderConfigurationEntry Route(
        string providerId,
        int priority,
        string approval = "Approved") => new()
    {
        ProviderId = providerId,
        DisplayName = providerId,
        AdapterIdentity = "Nexus.Intelligence.Tests.Adapter",
        Capabilities = [AiCapabilities.ChatComplete],
        Enabled = true,

        // The approved reference NAME. Never a value: no test in this suite has a credential to give,
        // and TASK 13 forbids any test requiring one.
        SecretReference = "NEXUS_TEST_API_KEY",
        PermitsRemoteEgress = false,
        Trust = "Approved",
        Priority = priority,
        Weight = 1.0,
        Approval = approval,
        MaxClassification = "Secret",

        // ApprovedBy is required for an approval to be reviewable, and is absent exactly when there is
        // no approval to review. A suspended route that still named an approver would be a record of
        // who approved something that is not approved.
        ApprovedBy = approval == "Approved" ? "test-owner" : null,
        GovernanceRationale = "W7E test fixture.",
    };

    /// <summary>One model, optionally priced, optionally restricted to particular processing tiers.</summary>
    public static AiModelConfigurationEntry ModelFor(
        string modelId,
        string providerId,
        decimal? inputRate = null,
        decimal? outputRate = null,
        string currency = "USD",
        string? priceStatus = null,
        IReadOnlyList<string>? processingTiers = null,
        string approval = "Approved") => new()
        {
            ModelId = modelId,
            ProviderId = providerId,
            DisplayName = modelId,
            Capabilities = [AiCapabilities.ChatComplete],
            MaxContextTokens = 200_000,
            MaxOutputTokens = 8_192,
            InputModalities = ["Text"],
            OutputModalities = ["Text"],
            Reasoning = "High",
            RelativeSpeed = "Normal",
            Availability = "Available",
            Enabled = true,
            InputCostPer1kTokens = inputRate,
            OutputCostPer1kTokens = outputRate,
            CostCurrency = inputRate is null ? null : currency,
            CostMetadataReference = inputRate is null ? null : "W7E test fixture.",
            PriceStatus = priceStatus,
            ProcessingTiers = [.. processingTiers ?? []],
            Approval = approval,
            MaxClassification = "Secret",
            ApprovedBy = approval == "Approved" ? "test-owner" : null,
            GovernanceRationale = "W7E test fixture.",
        };

    /// <summary>One health row, for a fixture declaring what a probe sweep has published.</summary>
    public static AiHealthConfigurationEntry HealthRow(string providerId, string state, string? modelId = null)
        => new() { ProviderId = providerId, ModelId = modelId, State = state };

    /// <summary>One budget covering the fixture's capability, with the caller's ceiling and behaviour.</summary>
    /// <remarks>
    /// Addressed at the capability rather than left unscoped, so the rule's scope is a fact the test
    /// can point at. The period is <see cref="AiBudgetPeriod.None"/> — a per-execution ceiling — for the
    /// same reason: a cumulative period would make the second run of a test differ from the first.
    /// </remarks>
    /// <param name="onUnpriced">
    /// W7F TASK 5's second posture. Left at the shipped default unless a test is about what an estate
    /// that requires pricing does, because changing it changes what every unpriceable route in the
    /// fixture means.
    /// </param>
    /// <param name="onExceeded">
    /// <b>W7G-R added this, because the reason code depends on it.</b> A ceiling an operator has said
    /// is absolute and a ceiling an operator has said a person may override are the same number and
    /// different controls, and the selector reports them differently
    /// (<see cref="AiFailoverReasonCode.AlternateOverBudget"/> against
    /// <see cref="AiFailoverReasonCode.BudgetRequiresOverride"/>). A fixture that could only express
    /// one of them left the other unreachable, which is a gap in the test and not in the estate.
    /// </param>
    /// <param name="period">
    /// <b>W7G-R added this for the same class of reason.</b> A per-execution ceiling is the same number
    /// before and after a failed attempt, so it cannot express "the estate could afford this route when
    /// it built the chain and cannot now". A windowed ceiling can, and that difference is the whole
    /// justification for the selector re-reading the gates at attempt time.
    /// </param>
    public static AiOperationsBudgetPolicy Budget(
        decimal ceiling,
        AiBudgetUncoveredBehaviour onUncovered = AiBudgetUncoveredBehaviour.Refuse,
        AiBudgetUncoveredBehaviour onUnpriced = AiBudgetUncoveredBehaviour.Allow,
        AiGovernanceVerdict onExceeded = AiGovernanceVerdict.Block,
        AiBudgetPeriod period = AiBudgetPeriod.None)
        => new()
        {
            Rules =
            [
                new AiOperationsBudgetRule
                {
                    RuleId = "budget.w7e.chat-complete",
                    Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
                    Ceiling = ceiling,
                    Currency = "USD",
                    Period = period,
                    OnExceeded = onExceeded,
                    Rationale = "W7E test fixture.",
                },
            ],
            Available = true,
            OnUncoveredPricedExecution = onUncovered,
            OnUnpricedExecution = onUnpriced,
        };

    /// <summary>Observed reliability for one route: how many attempts, and how many of them succeeded.</summary>
    /// <remarks>
    /// <para>
    /// Timestamps ascend from a fixed instant so the history is deterministic, and they are recent
    /// relative to nothing in particular because the shipped evidence lifetime is a day and these
    /// attempts are written "now" as far as the fixture is concerned — the history store reads its own
    /// clock, so a test that needs stale evidence constructs it explicitly at the bottom of this file.
    /// </para>
    /// <para>
    /// <b>The clock is a parameter, and W7G.2 F-6 is why.</b> This method used to stamp attempts from
    /// <see cref="DateTimeOffset.UtcNow"/> while the composed estate read
    /// <see cref="TimeProvider.System"/>. Any test that then asserted something about a circuit cooldown
    /// was really asserting that the machine reached the routing decision within the few milliseconds
    /// between the two readings — true in a warm suite, false on a cold isolated run. Passing the
    /// estate's own clock makes the seeded attempts and the decision that reads them agree by
    /// construction rather than by luck. The default stays <see cref="TimeProvider.System"/> so a caller
    /// that does not care is unaffected.
    /// </para>
    /// </remarks>
    public static IReadOnlyList<AiReliabilityAttempt> History(
        string providerId,
        string modelId,
        int succeeded,
        int failed,
        AiFailureCategory failureCategory = AiFailureCategory.ProviderUnavailable,
        TimeProvider? time = null)
    {
        var clock = time ?? TimeProvider.System;
        var attempts = new List<AiReliabilityAttempt>();
        var at = clock.GetUtcNow().AddMinutes(-1);

        for (var i = 0; i < succeeded + failed; i++)
        {
            var isSuccess = i < succeeded;

            attempts.Add(new AiReliabilityAttempt
            {
                ProviderId = providerId,
                ModelId = modelId,
                Succeeded = isSuccess,
                FailureCategory = isSuccess ? null : failureCategory,
                Latency = TimeSpan.FromMilliseconds(120),
                IsFallback = false,
                At = at,
            });

            at = at.AddMilliseconds(1);
        }

        return attempts;
    }
}
