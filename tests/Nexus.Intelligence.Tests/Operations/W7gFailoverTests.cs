using System.Collections.Generic;
using System.Linq;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Tests.Turns;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Operations;

// W7G-R TASK 4: the governed failover proof, completed.
//
// WHY THIS FILE EXISTS ALONGSIDE W7eFailoverTests. That suite proves the fallback plane's STRUCTURE -
// a healthy primary is not a failover, a governance refusal is never routed around, the chain is a
// slice of the eligible set. What it does not reach is the two families of refusal that only occur
// AFTER the chain was built, and the money on the route that actually ran. Those are the gaps this
// file closes, and they are listed here rather than left to be inferred:
//
//   1. GovernedAiFailoverSelector.HealthRefusal had no coverage at all. No test in the estate produced
//      AiFailoverReasonCode.AuthRequiresHuman, HealthUnknown or RouteUnhealthy, and no test anywhere
//      produced a non-empty AiFailoverStep.Skipped from the selector. The three refusals are the
//      estate's answer to "the route that was healthy when the chain was built is not healthy now",
//      which is the reason a selector re-reads anything.
//
//   2. A budget-refused FALLBACK had no coverage. Every budget refusal in the estate refused the
//      primary or a sole route, so AlternateOverBudget, AlternateBudgetUnknown and
//      BudgetRequiresOverride were unreachable - and "the fallback is refused on cost" is the
//      directive's own item.
//
//   3. Nothing asserted the selected attempt's OWN usage and cost on its own ledger entry, nor that a
//      failover's refused candidates are readable afterwards through the operations surface.
//
// WHY THE SELECTOR IS CALLED DIRECTLY IN SECTIONS A AND B. The state these refusals respond to is
// health and budget, and both are read by the ROUTER as well as by the selector. An end-to-end test
// that made a route unhealthy or unaffordable before the run would produce an empty chain, and would
// therefore be a test of routing - which W7eHealthAndReliabilityTests and W7eUsageAndCostTests
// already cover. The claim here is about what the selector does with a chain member that has changed
// since routing, and presenting the selector with a posture the router did not build the chain under
// is the only instrument that reaches it. Section C then proves the same property end to end, through
// the governed path, for the one case where the change happens on its own.
public sealed class W7gFailoverTests
{
    // ---------------------------------------------------------------------------------------------
    // A. A chain member that stopped answering since the chain was built.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AnAlternateWhoseProviderReportsAnAuthError_IsRefused_AsNeedingAHuman()
    {
        var (path, routing) = ChainedEstate();

        Observe(path, modelId: null, providerId: AlternateProvider, state: AiModelHealthState.AuthError);

        // The half that was NOT changed is asserted, so the refusal is attributable to the provider
        // observation rather than to a route that had stopped answering for some other reason.
        Assert.Equal(
            AiModelHealthState.Available,
            path.Health.Current.ModelState(AlternateModel, AlternateProvider));

        var step = Selector(path).Next(
            Request(), new AiRoutingContext(), routing, [], Failure(), DateTimeOffset.UtcNow);

        Assert.False(step.HasCandidate);
        Assert.Equal(AiFailoverReasonCode.FallbackDepthExhausted, step.ReasonCode);

        var skipped = Assert.Single(step.Skipped);

        Assert.Equal(AlternateModel, skipped.ModelId);
        Assert.Equal(AlternateProvider, skipped.ProviderId);
        Assert.Equal(AiFailoverAttemptOutcome.Rejected, skipped.Outcome);
        Assert.Equal(AiFailoverReasonCode.AuthRequiresHuman, skipped.ReasonCode);
        Assert.Equal(1, skipped.Order);

        // The reason is stated, and it states the remedy rather than only the symptom. "This route is
        // unavailable" and "a person has to act before this route can be used" are different facts for
        // whoever is on call, and only the second one tells them there is nothing to retry.
        Assert.Contains("human has to restore the credential", skipped.Detail, StringComparison.Ordinal);
    }

    [Fact]
    public void AnAlternateWhoseHealthHasNeverBeenObserved_IsRefused_AsUnknown()
    {
        var (path, routing) = ChainedEstate();

        // The model-scoped entry is what is withdrawn, and the provider stays healthy - so this is the
        // half of the health read that a provider-wide outage would not exercise.
        Observe(path, modelId: AlternateModel, providerId: AlternateProvider, state: AiModelHealthState.Unknown);

        Assert.Equal(AiModelHealthState.Available, path.Health.Current.ProviderState(AlternateProvider));

        var step = Selector(path).Next(
            Request(), new AiRoutingContext(), routing, [], Failure(), DateTimeOffset.UtcNow);

        Assert.False(step.HasCandidate);
        Assert.Equal(AiFailoverReasonCode.FallbackDepthExhausted, step.ReasonCode);

        var skipped = Assert.Single(step.Skipped);

        Assert.Equal(AlternateModel, skipped.ModelId);
        Assert.Equal(AiFailoverReasonCode.HealthUnknown, skipped.ReasonCode);

        // Unknown is its own code and not a flavour of unhealthy, because the two call for different
        // things: one is a route nobody has checked, the other is a route checked and found wanting.
        Assert.Contains("falling back to a route nobody has checked", skipped.Detail, StringComparison.Ordinal);
    }

    [Fact]
    public void AnAlternateWhoseProviderHasGoneDown_IsRefused_AsUnhealthy()
    {
        var (path, routing) = ChainedEstate();

        // A provider-wide outage. The model-scoped entry is left as it was, which is also the point:
        // the model's own observation still says Available, and the selector reads BOTH halves rather
        // than trusting the narrower one - a provider that is down makes its models unusable no matter
        // what was last observed about a model.
        Observe(path, modelId: null, providerId: AlternateProvider, state: AiModelHealthState.Unavailable);

        Assert.Equal(
            AiModelHealthState.Available,
            path.Health.Current.ModelState(AlternateModel, AlternateProvider));

        var step = Selector(path).Next(
            Request(), new AiRoutingContext(), routing, [], Failure(), DateTimeOffset.UtcNow);

        Assert.False(step.HasCandidate);
        Assert.Equal(AiFailoverReasonCode.FallbackDepthExhausted, step.ReasonCode);

        var skipped = Assert.Single(step.Skipped);

        Assert.Equal(AiFailoverReasonCode.RouteUnhealthy, skipped.ReasonCode);
        Assert.Contains("since the chain was built", skipped.Detail, StringComparison.Ordinal);
    }

    [Fact]
    public void TheSameChain_UnderTheHealthItWasBuiltWith_OffersTheAlternate_WhichIsWhatMakesItEvidence()
    {
        // CONTROL for all three refusals above. The same estate, the same chain, the same selector, the
        // same failure - and no health published. Without this, every test in section A would also pass
        // on a selector that had stopped offering candidates to anyone.
        var (path, routing) = ChainedEstate();

        var step = Selector(path).Next(
            Request(), new AiRoutingContext(), routing, [], Failure(), DateTimeOffset.UtcNow);

        Assert.True(step.HasCandidate);
        Assert.Equal(AiFailoverReasonCode.AttemptingAlternate, step.ReasonCode);
        Assert.Equal(AlternateModel, step.Candidate!.ModelId);
        Assert.Empty(step.Skipped);
    }

    // ---------------------------------------------------------------------------------------------
    // B. A chain member the estate can no longer afford.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AnAlternateOverAnAbsoluteCeiling_IsRefusedAsOverBudget()
    {
        var (path, routing) = ChainedEstate();

        var step = Selector(path, budget: Budget(ceiling: 0.0001m)).Next(
            Request(), Sized(inputTokens: 1_000, outputTokens: 1_000), routing, [], Failure(), DateTimeOffset.UtcNow);

        Assert.False(step.HasCandidate);
        Assert.Equal(AiFailoverReasonCode.FallbackDepthExhausted, step.ReasonCode);

        var skipped = Assert.Single(step.Skipped);

        Assert.Equal(AlternateModel, skipped.ModelId);
        Assert.Equal(AlternateProvider, skipped.ProviderId);
        Assert.Equal(AiFailoverAttemptOutcome.Rejected, skipped.Outcome);
        Assert.Equal(AiFailoverReasonCode.AlternateOverBudget, skipped.ReasonCode);

        // The refusal carries the decision that produced it, so the rule and the figure it was measured
        // at are on the record rather than reconstructable only from the ledger. The ceiling itself is
        // the rule's and is not restated on the verdict; the decision's reason names it, which is the
        // field a reader has, so that is what is asserted.
        Assert.NotNull(skipped.Budget);
        Assert.Equal(AiBudgetOutcome.RefusedOverCeiling, skipped.Budget!.Outcome);
        Assert.Equal("budget.w7e.chat-complete", skipped.Budget.RuleId);
        Assert.Equal(2.00m, skipped.Budget.ProjectedCost);
        Assert.Contains("0.0001", skipped.Budget.Reason!, StringComparison.Ordinal);

        // The selector is a pure function over a chain and cannot reach a provider, so this asserts the
        // estate was not otherwise touched rather than an invocation that the shape forbids. Section C
        // is where "never invoked" is proved about a real run.
        Assert.Equal([PrimaryModel], path.Model.ModelsAsked);
    }

    [Fact]
    public void AnAlternateOverACeilingAHumanMayOverride_IsRefusedAsNeedingThatDecision()
    {
        // The same number as the test above and a different control: the rule says a person may release
        // it. The distinction is the reason both codes exist - one is a ceiling that will not move, the
        // other is a decision waiting on somebody - and a selector that collapsed them would send the
        // second to the wrong queue.
        var (path, routing) = ChainedEstate();

        var step = Selector(path, budget: Budget(
            ceiling: 0.0001m,
            onExceeded: AiGovernanceVerdict.HumanDecisionRequired)).Next(
            Request(), Sized(inputTokens: 1_000, outputTokens: 1_000), routing, [], Failure(), DateTimeOffset.UtcNow);

        Assert.False(step.HasCandidate);

        var skipped = Assert.Single(step.Skipped);

        Assert.Equal(AiFailoverReasonCode.BudgetRequiresOverride, skipped.ReasonCode);

        // And it is still visibly a budget refusal, carrying the decision, so a reader is not left to
        // infer which gate wanted a human.
        Assert.NotNull(skipped.Budget);
        Assert.True(skipped.Budget!.RequiresHumanDecision);
    }

    [Fact]
    public void AnUnpriceableAlternate_IsRefusedAsBudgetUnknown_WhenTheEstateRequiresPrices()
    {
        // The alternate here is the one Priced() leaves unpriced, which is the estate's own answer to
        // "an unpriceable route is not a free route": the gate has nothing to compare, so it reports
        // that it has nothing to compare rather than treating silence as unlimited.
        var path = GovernedPath.Compose(Priced());
        var routing = Run(path).Routing!;

        Assert.NotEmpty(routing.FallbackChain);

        var step = Selector(path, budget: new AiOperationsBudgetPolicy
        {
            Rules =
            [
                new AiOperationsBudgetRule
                {
                    RuleId = "budget.w7e.chat-complete",
                    Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
                    Ceiling = 1_000m,
                    Currency = "USD",
                    Period = AiBudgetPeriod.None,
                    OnExceeded = AiGovernanceVerdict.Block,
                    Rationale = "W7G-R test fixture.",
                },
            ],
            Available = true,
            OnUnpricedExecution = AiBudgetUncoveredBehaviour.Refuse,
        }).Next(
            Request(), Sized(inputTokens: 1_000, outputTokens: 1_000), routing, [], Failure(), DateTimeOffset.UtcNow);

        Assert.False(step.HasCandidate);

        var skipped = Assert.Single(step.Skipped);

        Assert.Equal(AlternateModel, skipped.ModelId);
        Assert.Equal(AiFailoverReasonCode.AlternateBudgetUnknown, skipped.ReasonCode);

        // Unknown, not over. The ceiling was never reached because it was never measured, and reporting
        // this as "over budget" would state a comparison that did not happen.
        Assert.NotNull(skipped.Budget);
        Assert.Equal(AiBudgetOutcome.RefusedUnpriced, skipped.Budget!.Outcome);
        Assert.Null(skipped.Budget.RuleId);
    }

    [Fact]
    public void TheSameUnpricedAlternate_UnderTheShippedPosture_IsOffered_WhichIsWhatMakesItEvidence()
    {
        // CONTROL: the same estate, the same rule and ceiling, one field changed - the configured
        // behaviour for an unpriceable execution. The shipped posture allows it, and the alternate is
        // offered. Without this the refusal above would also pass on a selector that simply never
        // reached the unpriced branch.
        var path = GovernedPath.Compose(Priced());
        var routing = Run(path).Routing!;

        var step = Selector(path, budget: Budget(ceiling: 1_000m)).Next(
            Request(), Sized(inputTokens: 1_000, outputTokens: 1_000), routing, [], Failure(), DateTimeOffset.UtcNow);

        Assert.True(step.HasCandidate);
        Assert.Equal(AlternateModel, step.Candidate!.ModelId);
        Assert.Empty(step.Skipped);
    }

    // ---------------------------------------------------------------------------------------------
    // C. The re-evaluation, end to end: a ceiling the failed attempt has already consumed.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ACeilingTheFailedPrimaryHasAlreadyConsumed_RefusesTheAlternate_WhichIsNeverInvoked()
    {
        // The one case where the state changes by itself, so this is proved through the governed path
        // rather than by handing the selector a policy the router never saw.
        //
        // A per-execution ceiling cannot express this: the projection is the same figure before and
        // after an attempt. A daily ceiling can, and does - a failed attempt is real spend, it is on
        // the ledger by the time the failover asks for an alternate, and the alternate is then measured
        // against what is left rather than against the whole ceiling.
        //
        // WHICH FIGURE MAKES IT UNAFFORDABLE, exactly. The gate compares committed spend PLUS the
        // projection, and at failover time the committed figure is the failed attempt's measured cost:
        // one thousand tokens in and one thousand out, priced at 0.40 / 1.20, is 1.60. The projection
        // is taken over the routing context's own token estimate, which for this fixture's two-token
        // prompt is a fraction of a cent - so the ceiling is consumed by the MEASUREMENT of the attempt
        // that failed rather than by a prediction about the one that has not run. That is why the
        // ceiling below is small: it has to sit above both projections and below what the failed
        // attempt actually cost.
        var path = GovernedPath.Compose(PricedBoth(
            failingModels: [PrimaryModel],
            budget: Budget(ceiling: 0.05m, period: AiBudgetPeriod.Daily)));

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));

        // The primary was called once and the alternate never was. This is the directive's
        // "budget-blocked fallback never invoked", and it is a fact about the recording seam's call
        // count rather than about a decision object.
        Assert.Equal([PrimaryModel], path.Model.ModelsAsked);

        // The spend that made the alternate unaffordable is the failed attempt's, and it is on the
        // ledger although the attempt did not succeed. A ledger that recorded only successes would
        // leave the alternate looking affordable and the ceiling silently unenforced.
        var spent = Assert.Single(path.Ledger.Entries());

        Assert.Equal(PrimaryProvider, spent.ProviderId);
        Assert.False(spent.IsFallback);
        Assert.Equal(1.60m, spent.ActualCost);
        Assert.Equal("USD", spent.Currency);

        // And the refusal is on the record with its cause.
        Assert.NotNull(outcome.Failover);
        var failover = outcome.Failover!;

        Assert.False(failover.UsedFallback);
        Assert.False(failover.AttemptedAlternate);
        Assert.Null(failover.Selected);
        Assert.Equal(AiFailoverReasonCode.FallbackDepthExhausted, failover.ReasonCode);

        // The line above is where W7G-R found a defect, and it is asserted here because it is what
        // caught it. AiFailoverDecision.AttemptedAlternate tested for the Attempted outcome, which is
        // the outcome a FAILED PRIMARY gets — so this exact execution, whose primary failed and whose
        // only alternate was refused on cost, reported that an alternate had been attempted. The
        // control below is the other half: when the alternate really is attempted it must still say so.
        //
        // And the refused alternate is on the decision's attempt list as well as in its Rejected
        // subset, so a reader of the sequence sees where in it the refusal happened rather than only
        // that one happened.
        Assert.Equal(
            [AiFailoverAttemptOutcome.Attempted, AiFailoverAttemptOutcome.Rejected],
            failover.Attempts.Select(attempt => attempt.Outcome));

        var refused = Assert.Single(failover.Rejected);

        Assert.Equal(AlternateModel, refused.ModelId);
        Assert.Equal(AiFailoverReasonCode.AlternateOverBudget, refused.ReasonCode);
        Assert.NotNull(refused.Budget);
        Assert.Equal(AiBudgetOutcome.RefusedOverCeiling, refused.Budget!.Outcome);
        Assert.Equal(AiBudgetPeriod.Daily, refused.Budget.Period);

        // The committed figure is asserted exactly, because it is the whole point: it is the failed
        // attempt's measured cost and it is what closed the window. The projection is asserted only
        // as present and below the ceiling, because it is the routing context's estimate and a test
        // that pinned it would be pinning the size of the fixture's prompt.
        Assert.Equal(1.60m, refused.Budget.CommittedSpend);
        Assert.NotNull(refused.Budget.ProjectedCost);
        Assert.True(
            refused.Budget.ProjectedCost < 1.60m,
            $"the projection must be the small estimate, not the measurement, and it was {refused.Budget.ProjectedCost}");

        // The reason states the arithmetic rather than only the outcome: the committed figure and the
        // ceiling are both readable from the record.
        Assert.Contains("1.60", refused.Budget.Reason!, StringComparison.Ordinal);
        Assert.Contains("0.05", refused.Budget.Reason!, StringComparison.Ordinal);
    }

    [Fact]
    public void TheSameEstateUnderACeilingThatCoversBoth_FailsOver_WhichIsWhatMakesItEvidence()
    {
        // CONTROL: one field changed, the ceiling. The failed attempt's 1.60 plus the alternate's
        // projection fits under it, so the alternate is affordable at failover time and serves - which
        // is what makes the refusal above a statement about the ceiling rather than about a failover
        // that never worked.
        var path = GovernedPath.Compose(PricedBoth(
            failingModels: [PrimaryModel],
            budget: Budget(ceiling: 1.70m, period: AiBudgetPeriod.Daily)));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome), "A ceiling that covers both attempts must let the failover run.");
        Assert.Equal([PrimaryModel, AlternateModel], path.Model.ModelsAsked);
        Assert.True(outcome.Failover!.UsedFallback);

        // The other half of the correction above: an alternate that really was attempted is still
        // reported as attempted. Without this the refusal's `AttemptedAlternate == false` would also
        // pass on a property that had been made to answer false unconditionally.
        Assert.True(outcome.Failover.AttemptedAlternate);
    }

    // ---------------------------------------------------------------------------------------------
    // D. What the records carry afterwards.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheSelectedAlternate_CarriesItsOwnUsageAndCost_OnItsOwnLedgerEntry()
    {
        // The directive's "the selected attempt retains actual provider/model usage and cost". The
        // figure is asserted exactly rather than with a tolerance, because one thousand in and one
        // thousand out at 0.50 / 1.50 per thousand is 2.00, and a cost claim that cannot be stated
        // exactly is not one.
        var path = GovernedPath.Compose(PricedBoth(failingModels: [PrimaryModel]));

        Assert.True(Succeeded(Run(path)));

        var entries = path.Ledger.Entries();
        Assert.Equal(2, entries.Count);

        var failed = entries[0];
        var served = entries[1];

        // The two attempts are two records against one execution, and each names its own route.
        Assert.Equal(failed.ExecutionId, served.ExecutionId);
        Assert.NotEqual(failed.AttemptId, served.AttemptId);

        Assert.Equal(PrimaryModel, failed.ModelId);
        Assert.Equal(PrimaryProvider, failed.ProviderId);
        Assert.False(failed.IsFallback);

        Assert.Equal(AlternateModel, served.ModelId);
        Assert.Equal(AlternateProvider, served.ProviderId);
        Assert.True(served.IsFallback);

        // The selected attempt's own tokens, its own rate-derived cost, and the basis that says the
        // figure came from what the provider reported rather than from a prediction.
        Assert.Equal(1_000, served.TokensIn);
        Assert.Equal(1_000, served.TokensOut);
        Assert.Equal(2_000, served.TotalTokens);
        Assert.Equal(2.00m, served.ActualCost);
        Assert.Equal(AiCostBasis.ActualRecorded, served.CostBasis);
        Assert.Equal(2.00m, served.AuthoritativeCost);
        Assert.Equal("USD", served.Currency);

        // The prediction and the measurement are both kept, and they are allowed to disagree. They do:
        // the router sizes this fixture's work at a couple of tokens and the recording provider reports
        // a thousand, so the prediction is a fraction of a cent and the measurement is 2.00. A record
        // that kept only one of them would make the other unrecoverable, and the disagreement is the
        // fact an operator reconciling a bill actually needs.
        Assert.NotNull(served.EstimatedCost);
        Assert.NotEqual(served.ActualCost, served.EstimatedCost);
        Assert.Equal(served.ActualCost, served.AuthoritativeCost);
        Assert.NotNull(served.PriceQuoteId);
    }

    [Fact]
    public void TheOperationsSurface_ReportsEveryAttemptOfAFailover_WithItsOutcomeAndItsEvidence()
    {
        var path = GovernedPath.Compose(PricedBoth(failingModels: [PrimaryModel]));

        var outcome = Run(path);
        Assert.True(Succeeded(outcome));

        // One execution, two provider calls. The execution identity is asserted to be ONE value across
        // both entries rather than to be one entry, because the whole point of W7F TASK 2's split is
        // that a failover's two invocations are two attempts of one execution - a fallback that minted
        // its own execution identity would make the spend unsummable and the audit record
        // unjoinable.
        var executionId = Assert.Single(path.Ledger.Entries().Select(entry => entry.ExecutionId).Distinct());

        Assert.Equal(2, path.Ledger.Entries().Select(entry => entry.AttemptId).Distinct().Count());

        // Read back through the surface an operator actually uses, not through the decision object the
        // governed path happened to be holding. A record that only existed in memory would answer a
        // question nobody outside the request can ask.
        var view = path.Operations.Execution(executionId);

        Assert.NotNull(view);
        Assert.Equal(executionId, view!.ExecutionId);
        Assert.True(view.UsedFallback);
        Assert.Equal(AiFailoverReasonCode.AlternateSucceeded, view.FailoverReasonCode);

        Assert.Equal(2, view.FailoverAttempts.Count);

        var primary = Assert.Single(view.FailoverAttempts, attempt => attempt.ModelId == PrimaryModel);
        Assert.Equal(0, primary.Order);
        Assert.Equal(AiFailoverAttemptOutcome.Attempted, primary.Outcome);

        // The route that ran carries the governance decision it was admitted under. An attempt record
        // without one would be a call that cannot be traced to the verdict that permitted it.
        Assert.NotNull(primary.Governance);
        Assert.True(primary.Governance!.IsAllowed);

        var alternate = Assert.Single(view.FailoverAttempts, attempt => attempt.ModelId == AlternateModel);
        Assert.Equal(1, alternate.Order);
        Assert.Equal(AiFailoverAttemptOutcome.AlternateSucceeded, alternate.Outcome);
        Assert.Equal(AiFailoverReasonCode.AlternateSucceeded, alternate.ReasonCode);
        Assert.NotNull(alternate.Governance);
        Assert.True(alternate.Governance!.IsAllowed);

        // The execution's own totals are the sum of its attempts, and its cost is the authoritative
        // figure from the measured basis rather than a prediction standing in for one. Both attempts
        // were priced at one thousand in and one thousand out, so the execution cost 1.60 + 2.00.
        Assert.Equal(2_000, view.TokensIn);
        Assert.Equal(2_000, view.TokensOut);
        Assert.Equal(3.60m, view.Cost);
        Assert.Equal(AiCostBasis.ActualRecorded, view.CostBasis);
        Assert.Equal("USD", view.Currency);

        // And the fallback is separable within the spend, which is what lets a cost regression caused
        // by failover be told apart from one caused by the primary route.
        var fallbackSpend = Assert.Single(path.Ledger.Entries(), entry => entry.IsFallback);
        Assert.Equal(2.00m, fallbackSpend.ActualCost);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    /// <summary>The two-route priced estate, run once, with its routing outcome.</summary>
    /// <remarks>
    /// Running it is not incidental: the chain the selector walks is produced by the router, and a test
    /// that constructed one by hand would be testing the selector against a chain the router might never
    /// emit. <see cref="GovernedAiFailoverSelector"/> reads live registries and live health, so the
    /// estate has to exist and be composed before there is anything to ask.
    /// </remarks>
    private static (GovernedPath Path, AiRoutingOutcome Routing) ChainedEstate()
    {
        var path = GovernedPath.Compose(PricedBoth());

        var routing = Run(path).Routing;

        Assert.NotNull(routing);
        Assert.NotEmpty(routing!.FallbackChain);

        // The alternate is the only chain member, so a test's single skip is this route and not another
        // one that happened to be refused first.
        Assert.Equal(AlternateModel, Assert.Single(routing.FallbackChain).ModelId);

        return (path, routing);
    }

    /// <summary>
    /// The routing context a test hands a gate it is calling directly, sized to the work it names.
    /// </summary>
    /// <remarks>
    /// <b>This is NOT the context the router decided with, and it must not be described as one.</b>
    /// <see cref="AiRoutingOutcome"/> does not carry its context — the token counts live on
    /// <see cref="AiRoutingContext"/>, not on the candidates it admitted — so a test that wants the
    /// budget gate to evaluate a request of a stated size has to state the size. What that buys is
    /// exactness: one thousand in and one thousand out is 2.00 on a route rated 0.50 / 1.50, so the
    /// ceiling the refusal is measured against is a figure the test can check rather than a figure it
    /// inferred. It is sound here because the claim under test is about the gate's arithmetic over a
    /// chain member, and section C is where the same property is proved end to end, on the router's
    /// own context, with no context supplied by a test at all.
    /// </remarks>
    private static AiRoutingContext Sized(int inputTokens, int outputTokens) => new()
    {
        InputTokens = inputTokens,
        OutputTokens = outputTokens,
    };

    /// <summary>Publishes a snapshot in which one target has been observed to be in <paramref name="state"/>.</summary>
    /// <remarks>
    /// Published AFTER the estate has been run, which is the point: the router built its chain under
    /// the healthy snapshot, and this is the change the selector is being asked to notice. A snapshot
    /// published before the run would change what the router admitted and would test routing instead.
    /// <paramref name="modelId"/> null means a provider-wide observation; a model identifier means a
    /// model-scoped one. The two are read separately by the selector and both are exercised above.
    /// </remarks>
    private static void Observe(
        GovernedPath path, string? modelId, string providerId, AiModelHealthState state)
    {
        var current = path.Health.Current;

        var providers = new Dictionary<string, AiModelHealthState>(current.Providers, StringComparer.Ordinal);
        var models = new Dictionary<(string ModelId, string ProviderId), AiModelHealthState>(current.Models);

        if (modelId is null)
        {
            providers[providerId] = state;
        }
        else
        {
            models[(modelId, providerId)] = state;
        }

        path.Health.Publish(current with { Providers = providers, Models = models });
    }
}
