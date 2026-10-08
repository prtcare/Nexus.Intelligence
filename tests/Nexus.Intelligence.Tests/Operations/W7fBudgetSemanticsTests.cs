using System;
using System.Collections.Generic;
using System.Linq;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Tests.Turns;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Operations;

// W7F TASK 4 and TASK 5: what the operational budget gate concluded, stated rather than inferred, and
// what an unpriceable route means to a reader.
//
// WHY THIS FILE EXISTS. W7E put the budget verdict on the operations view as a governance verdict and a
// rule identifier, and left the reader to work out WHICH decision it was looking at from the execution's
// overall status. That is wrong in the direction that matters: a route the ceiling refused while another
// route served is a real finding, and a reader who took the status for an answer would report a
// completed execution as blocked by a budget — or attribute a policy refusal to the budget gate. W7F
// TASK 4 replaces the inference with a member, and this file asserts it from both sides.
//
// THE OTHER HALF IS ARITHMETIC. Three different facts used to arrive as the same decision —
// { Allow, RuleId = null } — and one of them was "this route has no price". A surface that reported that
// as a permission with no ceiling is a surface where an unpriceable model reads as a free one.
//
// WHAT MAKES THESE TESTS WORTH RUNNING. Every one composes the real governed path — the real W7B
// engine, the real W7C router and registry, the real W7D stages, the real W7E gate, ledger and evidence
// store — and reads the answer back through the operations read model an operator actually uses, not
// through the evaluator's return value. Every guard is paired with a control that changes one field and
// produces the opposite reading from the same estate.
public sealed class W7fBudgetSemanticsTests
{
    // ---------------------------------------------------------------------------------------------
    // TASK 4: conclusions that used to be one.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AGateThatWasNeverComposed_SaysSo_RatherThanReadingAsAnAllow()
    {
        // The estate has not composed an operational budget plane, so the gate was never asked. It
        // permitted the execution, and that permission is not a statement about money.
        var path = GovernedPath.Compose(UnpricedSole());

        var outcome = Run(path);

        Assert.True(Succeeded(outcome), "The fixture must route for this test to mean anything.");

        var view = path.Operations.Execution(outcome.AuditReference!)!;

        // The decision exists and says what it is: no plane, no evaluation, no rule.
        Assert.NotNull(view.Budget);
        Assert.Equal(AiBudgetOutcome.NotConfigured, view.Budget!.Outcome);
        Assert.True(view.Budget.IsAllowed);
        Assert.Null(view.BudgetRuleId);

        // ...and the reading names which decision it came from, which is the route that served.
        Assert.Equal(AiBudgetReading.SelectedRoute, view.BudgetReading);

        // NON-VACUITY: composing a plane changes the outcome from the same estate, so NotConfigured is a
        // fact about the policy rather than the only value this member ever takes.
        var configured = GovernedPath.Compose(UnpricedSole(budget: Budget(ceiling: 100m)));

        var configuredView = configured.Operations.Execution(Run(configured).AuditReference!)!;

        Assert.Equal(AiBudgetOutcome.Unpriced, configuredView.Budget!.Outcome);
        Assert.NotEqual(view.Budget!.Outcome, configuredView.Budget!.Outcome);
    }

    [Fact]
    public void AnUnpriceableRoute_IsPermittedAndReportedAsUnpriced_NeverAsFree()
    {
        // TASK 5's first clause. The route is permitted — the shipped posture leaves "may this estate run
        // work it cannot cost" to the governance cost gate — and what the gate must not do is report
        // that permission as coverage.
        var path = GovernedPath.Compose(UnpricedSole(budget: Budget(ceiling: 100m)));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));

        var view = path.Operations.Execution(outcome.AuditReference!)!;

        // Nothing was compared. The gate says so on the member rather than in the verdict, because an
        // allow with no outcome is indistinguishable from a satisfied ceiling.
        Assert.Equal(AiBudgetOutcome.Unpriced, view.Budget!.Outcome);
        Assert.True(view.Budget.IsAllowed);

        // The rule identifier is null and the OUTCOME is what explains it. A rule covering this
        // capability does exist — asserted next — and it did not apply, because there was no figure to
        // compare against its ceiling. A reader who took the null identifier for "no ceiling applied,
        // therefore nothing was spent" would be reading a null as a measurement.
        Assert.Null(view.BudgetRuleId);
        Assert.NotEmpty(path.Options.Budget!.Rules);

        // ...and the money is absent rather than zero.
        Assert.Equal(AiCostBasis.Unpriced, view.CostBasis);
        Assert.Null(view.Cost);

        // CONTROL: the same estate, the same rule, one field changed on the model — a rates pair. Now the
        // rule applies, the ceiling is compared, and the amount is on the view. Without this, the
        // assertions above would also hold on a read model that never priced anything.
        var priced = GovernedPath.Compose(PricedSole(budget: Budget(ceiling: 100m)));

        var pricedView = priced.Operations.Execution(Run(priced).AuditReference!)!;

        Assert.Equal(AiBudgetOutcome.WithinCeiling, pricedView.Budget!.Outcome);
        Assert.Equal("budget.w7e.chat-complete", pricedView.BudgetRuleId);
        Assert.NotEqual(AiCostBasis.Unpriced, pricedView.CostBasis);
        Assert.NotNull(pricedView.Cost);

        // ...and the projection is carried by the outcome that names a COMPARISON and withheld by the
        // outcome that says no figure existed. TASK 4: a WithinCeiling with no projection states that a
        // ceiling was satisfied and leaves the reader to reconstruct the margin from the cost ledger,
        // which is the inference this task exists to remove. Null here reads as "nothing was measured",
        // not as "something was measured and is not being shown".
        Assert.NotNull(pricedView.Budget.ProjectedCost);
        Assert.Null(view.Budget!.ProjectedCost);
    }

    [Fact]
    public void AnUnpriceableRoute_IsRefused_WhenTheEstateRequiresARouteItCanPrice()
    {
        // TASK 5's last clause: fail-closed behaviour stays expressible. One policy field, and the same
        // estate that ran above refuses to run at all.
        var path = GovernedPath.Compose(UnpricedSole(budget: Budget(
            ceiling: 100m,
            onUnpriced: AiBudgetUncoveredBehaviour.Refuse)));

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));
        Assert.False(outcome.Invoked);

        // Nothing reached the seam and nothing was spent, so the refusal is the gate's rather than a
        // failure the fixture happened to produce.
        Assert.Equal(0, path.Model.Count);
        Assert.Empty(path.Ledger.Entries());

        var view = path.Operations.Execution(outcome.AuditReference!)!;

        Assert.Equal(AiExecutionStatus.Blocked, view.Status);
        Assert.Equal(AiBudgetOutcome.RefusedUnpriced, view.Budget!.Outcome);
        Assert.True(view.Budget.IsBlocked);

        // The refusal is the decision that stopped the execution and the reading says so, so an operator
        // never derives that from the status.
        Assert.Equal(AiBudgetReading.Refusal, view.BudgetReading);

        // CONTROL: the same refusal, one field changed back. Same estate, same route, same absence of a
        // price — and it runs.
        var permitted = GovernedPath.Compose(UnpricedSole(budget: Budget(
            ceiling: 100m,
            onUnpriced: AiBudgetUncoveredBehaviour.Allow)));

        var permittedView = permitted.Operations.Execution(Run(permitted).AuditReference!)!;

        Assert.Equal(AiBudgetOutcome.Unpriced, permittedView.Budget!.Outcome);
        Assert.NotEqual(view.Status, permittedView.Status);
    }

    [Fact]
    public void ACeilingThatWasExceeded_NamesItsRule_AndAnUncoveredRouteNamesNone()
    {
        // The pair that used to be indistinguishable: both blocked, both BudgetBlocked, differing only in
        // the prose of a reason. Their remedies differ too — one is to raise a ceiling, the other is to
        // write a rule — so a reader who cannot tell them apart is being sent to the wrong file.
        var exceeded = GovernedPath.Compose(PricedSole(budget: Budget(ceiling: 0.0001m)));

        var exceededView = exceeded.Operations.Execution(Run(exceeded).AuditReference!)!;

        Assert.Equal(AiBudgetOutcome.RefusedOverCeiling, exceededView.Budget!.Outcome);
        Assert.Equal("budget.w7e.chat-complete", exceededView.BudgetRuleId);
        Assert.Equal(AiBudgetReading.Refusal, exceededView.BudgetReading);

        // The other reading of the same route: priced, and no rule covers it.
        var uncovered = GovernedPath.Compose(PricedSole(budget: new AiOperationsBudgetPolicy
        {
            Rules = [],
            Available = true,
            OnUncoveredPricedExecution = AiBudgetUncoveredBehaviour.Refuse,
        }));

        var uncoveredView = uncovered.Operations.Execution(Run(uncovered).AuditReference!)!;

        Assert.Equal(AiBudgetOutcome.RefusedUncovered, uncoveredView.Budget!.Outcome);
        Assert.Null(uncoveredView.BudgetRuleId);
        Assert.Equal(AiBudgetReading.Refusal, uncoveredView.BudgetReading);

        // Both stopped at cost, both blocked, one with a rule to name and one without — and the outcomes
        // are what separate them.
        Assert.NotEqual(exceededView.Budget!.Outcome, uncoveredView.Budget!.Outcome);
        Assert.NotEqual(exceededView.BudgetRuleId, uncoveredView.BudgetRuleId);
        Assert.Equal(exceededView.Status, uncoveredView.Status);

        // NON-VACUITY: the two estates really do differ by their rule table and nothing else, so the pair
        // above is a statement about coverage rather than about two differently-shaped fixtures.
        Assert.NotEmpty(exceeded.Options.Budget!.Rules);
        Assert.Empty(uncovered.Options.Budget!.Rules);
    }

    [Fact]
    public void AnUncoveredPricedRoute_IsPermittedOrRefused_ByOnePolicyField_AndBothAreNamed()
    {
        // The two answers to one question. Neither is the same statement as "a ceiling covered this", and
        // a surface that reported them as one would leave an estate's deliberate widening invisible.
        var permissive = GovernedPath.Compose(PricedSole(budget: new AiOperationsBudgetPolicy
        {
            Rules = [],
            Available = true,
            OnUncoveredPricedExecution = AiBudgetUncoveredBehaviour.Allow,
        }));

        var permittedView = permissive.Operations.Execution(Run(permissive).AuditReference!)!;

        Assert.Equal(AiBudgetOutcome.AllowedUncovered, permittedView.Budget!.Outcome);
        Assert.True(permittedView.Budget.IsAllowed);
        Assert.Null(permittedView.BudgetRuleId);

        // The route IS priced, so "no rule applied" above is a statement about coverage rather than
        // about a missing price — which is the distinction AllowedUncovered and Unpriced exist to draw.
        Assert.NotNull(permittedView.Cost);

        var strict = GovernedPath.Compose(PricedSole(budget: new AiOperationsBudgetPolicy
        {
            Rules = [],
            Available = true,
            OnUncoveredPricedExecution = AiBudgetUncoveredBehaviour.Refuse,
        }));

        var refusedView = strict.Operations.Execution(Run(strict).AuditReference!)!;

        Assert.Equal(AiBudgetOutcome.RefusedUncovered, refusedView.Budget!.Outcome);
        Assert.False(refusedView.Budget.IsAllowed);
        Assert.NotEqual(permittedView.Budget!.Outcome, refusedView.Budget!.Outcome);
    }

    [Fact]
    public void ARouteTheCeilingRefused_WhileAnotherServed_IsNotReportedAsThisExecutionsVerdict()
    {
        // TASK 4's actual failure mode, and the reason a reading has to be stated rather than derived
        // from the status. The priced primary is refused by the ceiling; the unpriced alternate serves.
        // The execution carries a real, recorded budget refusal — and its own budget decision is the
        // allow the gate made about the route that ran, so the reading is SelectedRoute and the outcome
        // is Unpriced.
        //
        // A view that published the refusal because a refusal existed would tell an operator that a
        // completed execution was blocked by a budget, and would hide the substitution that actually
        // happened.
        var path = GovernedPath.Compose(Priced(budget: Budget(ceiling: 0.0001m)));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome), "The unpriced alternate must have served the request.");

        // The refusal really happened and really is on the record — otherwise this test would pass on an
        // estate where nothing was refused and would prove nothing.
        Assert.Contains(
            outcome.Routing!.OperationalFindings,
            finding => finding.Reason is AiRoutingRejectionReason.BudgetExceeded);

        var view = path.Operations.Execution(outcome.AuditReference!)!;

        Assert.Equal(AiBudgetReading.SelectedRoute, view.BudgetReading);
        Assert.Equal(AiBudgetOutcome.Unpriced, view.Budget!.Outcome);
        Assert.Null(view.BudgetRuleId);
        Assert.NotEqual(AiGovernanceVerdict.Block, view.BudgetVerdict);
    }

    [Fact]
    public void AnExecutionBlockedBeforeRouting_ReportsNoBudgetReading_WhichIsNotAnAllow()
    {
        // The third reading. Nothing was selected and nothing was refused at cost, so the view reports
        // None — and None is not an allow, which is the whole reason it is a member rather than a null
        // a consumer is invited to fill in with whatever the status suggests.
        var path = GovernedPath.Compose(PricedSole(budget: Budget(ceiling: 100m)));

        var blocked = Run(
            path,
            GovernedPath.Turn(path.Options, agentId: "developer", promptId: "prompt.not-registered"));

        Assert.False(blocked.Invoked);

        var view = path.Operations.Execution(blocked.AuditReference!)!;

        // Blocked, and not by cost: the refusal happened at the instruction set, before any route was
        // evaluated. Reading the budget verdict off the status would have produced a budget refusal here.
        Assert.Equal(AiExecutionStatus.Blocked, view.Status);
        Assert.Equal(AiBudgetReading.None, view.BudgetReading);
        Assert.Null(view.Budget);
        Assert.Null(view.BudgetVerdict);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 4: the members cannot disagree with the decision they project.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheFlatBudgetMembers_AgreeWithTheDecisionTheyProject()
    {
        // The view carries the whole decision AND its two most-read fields flat. Two representations of
        // one fact is a disagreement waiting to happen, so it is asserted on a permitted execution, a
        // refused one and a substituted one rather than trusted from a single easy case.
        AssertAgree(GovernedPath.Compose(PricedSole(budget: Budget(ceiling: 100m))));
        AssertAgree(GovernedPath.Compose(PricedSole(budget: Budget(ceiling: 0.0001m))));
        AssertAgree(GovernedPath.Compose(UnpricedSole(budget: Budget(ceiling: 100m))));

        // NON-VACUITY: the members agree and are NOT all null, so the assertions are not satisfied by a
        // view that carries nothing at all.
        var priced = GovernedPath.Compose(PricedSole(budget: Budget(ceiling: 100m)));
        var view = priced.Operations.Execution(Run(priced).AuditReference!)!;

        Assert.NotNull(view.Budget);
        Assert.NotNull(view.BudgetVerdict);
        Assert.NotNull(view.BudgetRuleId);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 5: the priced route a failover replaced with one the estate cannot price.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void APricedRouteReplacedByAnUnpriceableOne_IsRecordedAsASubstitution()
    {
        // The estate prices its primary and has no rates for its alternate. The primary is permitted,
        // attempted and fails; the alternate serves. Every ceiling this estate wrote was measured against
        // a route that did not run, and the route that did run has no figure at all.
        var path = GovernedPath.Compose(
            Priced(budget: Budget(ceiling: 100m)) with { FailingModels = [PrimaryModel] });

        var outcome = Run(path);

        Assert.True(Succeeded(outcome), "The alternate must have served the request.");

        // The estate really did select the priced primary and then move off it. Asserted rather than
        // assumed, because ranking reads cost: an estate whose alternate is CHEAPER would have selected
        // the alternate to begin with, failed over from nothing, and this test would have passed while
        // testing something else entirely.
        Assert.Equal(PrimaryModel, outcome.Routing!.Selected!.ModelId);
        Assert.True(outcome.Failover!.UsedFallback);

        var view = path.Operations.Execution(outcome.AuditReference!)!;
        var substitution = view.BudgetSubstitution;

        Assert.NotNull(substitution);
        Assert.Equal(PrimaryModel, substitution!.FromModelId);
        Assert.Equal(PrimaryProvider, substitution.FromProviderId);
        Assert.Equal(AlternateModel, substitution.ToModelId);
        Assert.Equal(AlternateProvider, substitution.ToProviderId);

        // The projection is the one the ROUTING decision priced the route at, not a second computation.
        // Asserted as a relationship, so the test cannot pass by agreeing with a constant that happens to
        // be right for this fixture.
        var primary = Assert.Single(outcome.Routing!.Eligible, candidate => candidate.ModelId == PrimaryModel);

        Assert.Equal(primary.EstimatedCost!.Value, substitution.FromProjectedCost);
        Assert.Equal(primary.CostCurrency, substitution.FromCurrency);

        // The route that served has no price at all. Asserted on its OWN ledger entry rather than inferred
        // from the execution's total, because the total is dominated by the attempt that failed and would
        // hide the served route's absence inside a figure that looks complete.
        var served = Assert.Single(path.Ledger.Entries(), entry => entry.ModelId == AlternateModel);

        Assert.True(served.IsFallback);
        Assert.Equal(AiCostBasis.Unpriced, served.CostBasis);
        Assert.Null(served.ActualCost);
        Assert.Null(served.EstimatedCost);

        // ...and the execution's own figure is the FAILED attempt's, which is a real measurement of what
        // the estate paid and is not a figure for the work the caller received. Those are two different
        // questions; the view answers the first, and the substitution above answers the second. A read
        // model that suppressed the measured amount because the serving route was unpriceable would be
        // hiding money that was actually spent.
        Assert.Equal(AiCostBasis.ActualRecorded, view.CostBasis);
        Assert.NotNull(view.Cost);
        Assert.True(view.Cost > 0m, "The failed priced attempt spent money and the ledger records it.");

        // ...and the budget verdict is the one the gates reached about the route the ROUTER selected —
        // the priced one, which passed its ceiling. That is not a claim about the route that served, and
        // the substitution above is the member that says so. Reading the verdict as a statement about
        // the serving route is the misreading these two members exist to prevent.
        Assert.Equal(AiBudgetReading.SelectedRoute, view.BudgetReading);
        Assert.Equal(AiBudgetOutcome.WithinCeiling, view.Budget!.Outcome);
        Assert.Equal("budget.w7e.chat-complete", view.BudgetRuleId);

        // The decision's own projection is the priced route's, which is the same relationship the
        // substitution asserts above — restated here from the other end, so a build that populated the
        // substitution from one source and the decision from another cannot pass both.
        Assert.Equal(primary.EstimatedCost!.Value, view.Budget.ProjectedCost);
    }

    [Fact]
    public void AFailoverBetweenTwoPricedRoutes_IsNotASubstitution()
    {
        // CONTROL for the substitution above, and the reason it is derived from the failover record
        // rather than recorded whenever a failover happens. One field changed — the alternate's rates —
        // and the same failover, from the same primary failure, loses no coverage and reports no
        // substitution.
        //
        // THE ALTERNATE'S RATES ARE DELIBERATELY WORSE, NOT BETTER. Ranking reads cost, so an alternate
        // priced BELOW the primary would win the ranking outright, become the primary, and never fail
        // over from anything — the control would then pass while observing no failover at all. Worse
        // rates keep the higher-priority primary in front, which is what makes the fallback real.
        var path = GovernedPath.Compose(
            Priced(budget: Budget(ceiling: 100m)) with
            {
                FailingModels = [PrimaryModel],
                Models =
                [
                    ModelFor(PrimaryModel, PrimaryProvider, inputRate: 0.50m, outputRate: 1.50m),
                    ModelFor(AlternateModel, AlternateProvider, inputRate: 5.00m, outputRate: 15.00m),
                ],
            });

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));

        // Asserted, not assumed: this whole control is meaningless unless the estate selected the priced
        // primary and the failover is what put the work on the priced alternate.
        Assert.Equal(PrimaryModel, outcome.Routing!.Selected!.ModelId);

        var view = path.Operations.Execution(outcome.AuditReference!)!;

        // The failover really happened — otherwise this control would pass on an estate where nothing
        // fell over, and would prove nothing about the substitution rule.
        Assert.True(view.UsedFallback);
        Assert.Equal(AlternateModel, view.ModelId);

        Assert.Null(view.BudgetSubstitution);

        // ...and the serving route IS priced, which is what makes the absence above a statement about
        // coverage rather than about a route nobody costed.
        Assert.NotEqual(AiCostBasis.Unpriced, view.CostBasis);
    }

    [Fact]
    public void TheSubstitutionRule_AnswersOnlyForAPricedPrimaryAndAnUnpricedServedRoute()
    {
        // The boundary of the rule, exercised where it lives, over candidates the estate's OWN router
        // produced rather than over hand-built ones — so the inputs are the shapes the rule is really
        // called with.
        var path = GovernedPath.Compose(Priced());

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));

        var priced = Assert.Single(outcome.Routing!.Eligible, candidate => candidate.ModelId == PrimaryModel);
        var unpriced = Assert.Single(outcome.Routing!.Eligible, candidate => candidate.ModelId == AlternateModel);

        Assert.NotNull(AiBudgetSubstitution.Between(priced, unpriced));

        // Nothing failed over: there is no route that lost, so nothing lost coverage.
        Assert.Null(AiBudgetSubstitution.Between(null, unpriced));

        // Nothing served: an execution that reached no route substituted nothing.
        Assert.Null(AiBudgetSubstitution.Between(priced, null));

        // The route that served can be priced, so no figure the estate had was lost.
        Assert.Null(AiBudgetSubstitution.Between(priced, priced));

        // The route that failed was unpriceable too, so the estate lost no figure it had.
        Assert.Null(AiBudgetSubstitution.Between(unpriced, unpriced));

        // A priced route with no stated currency cannot be compared against a ceiling at all, so it is
        // not reported as coverage that was lost. One field changed on the same candidate.
        Assert.Null(AiBudgetSubstitution.Between(priced with { CostCurrency = null }, unpriced));
    }

    [Fact]
    public void ABucket_SaysHowManyOfItsExecutionsItCouldNotPrice()
    {
        // TASK 5 at the rollup: the summed cost is a total over the executions that had a price, and the
        // count beside it is what keeps that total from reading as a bucket that cost nothing.
        var unpriced = GovernedPath.Compose(UnpricedSole());

        Run(unpriced);
        Run(unpriced);

        var unpricedSummary = unpriced.Operations.Summarize(new AiOperationsQuery(), AiUsageGroupBy.Execution);

        Assert.Equal(2, unpricedSummary.Executions);
        Assert.Equal(2, unpricedSummary.UnpricedExecutions);
        Assert.Equal(0m, unpricedSummary.Buckets.Sum(bucket => bucket.Cost));

        // Every execution in the rollup is accounted for by the count, so the zero above is explained
        // rather than asserted away.
        Assert.All(
            unpricedSummary.Buckets,
            bucket => Assert.Equal(bucket.Executions, bucket.UnpricedExecutions));

        // CONTROL: an estate whose routes are priced reports none unpriced and a non-zero total, so the
        // count is a measurement of the bucket rather than a constant.
        var priced = GovernedPath.Compose(PricedSole(budget: Budget(ceiling: 100m)));

        Run(priced);
        Run(priced);

        var pricedSummary = priced.Operations.Summarize(new AiOperationsQuery(), AiUsageGroupBy.Execution);

        Assert.Equal(2, pricedSummary.Executions);
        Assert.Equal(0, pricedSummary.UnpricedExecutions);
        Assert.True(
            pricedSummary.Buckets.Sum(bucket => bucket.Cost) > 0m,
            "A priced estate must report a cost, or the control proves nothing.");
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    /// <summary>Asserts that a view's flat budget members are the projection of the decision it carries.</summary>
    /// <remarks>
    /// A refused execution's decision comes from the router's findings rather than from a selected
    /// candidate, so this covers both provenances. Where there is no decision at all the three members
    /// must be absent together rather than each absent for its own reason.
    /// </remarks>
    private static void AssertAgree(GovernedPath path)
    {
        var outcome = Run(path);
        var view = path.Operations.Execution(outcome.AuditReference!)!;

        if (view.Budget is not { } decision)
        {
            Assert.Null(view.BudgetVerdict);
            Assert.Null(view.BudgetRuleId);
            Assert.Equal(AiBudgetReading.None, view.BudgetReading);

            return;
        }

        Assert.Equal(decision.Verdict, view.BudgetVerdict);
        Assert.Equal(decision.RuleId, view.BudgetRuleId);

        // ...and an outcome is always stated, never left at the default a decision constructed without one
        // would carry. A default here would be the same silence TASK 4 removed, one member along.
        Assert.NotEqual(AiBudgetOutcome.NotEvaluated, decision.Outcome);

        // The reading is stated too, and it is one of the two that mean "a decision was recorded".
        Assert.NotEqual(AiBudgetReading.None, view.BudgetReading);
    }
}
