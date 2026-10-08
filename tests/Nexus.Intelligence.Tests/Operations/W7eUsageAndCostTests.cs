using System.Collections.Generic;
using System.Linq;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Tests.Turns;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Operations;

// W7E TASK 14: usage accounting and the cost ledger, asserted against the REAL governed path.
//
// WHAT MAKES THESE TESTS EVIDENCE. The usage ledger, the cost ledger, the price catalogue, the budget
// evaluator and the operational gate are the estate's own implementations, composed exactly as
// Nexus.Intelligence.Api composes them. The only fake is the model step, and it is the instrument:
// "one ledger entry per provider call" is a count on a record the production recorder wrote, not a
// count a stub was told to report.
//
// WHY EVERY GUARD HAS A CONTROL. A test that a priced execution is refused passes on a system that
// refuses everything. Each refusal below is therefore paired with the same fixture reduced to the
// permissive case, so the refusal is attributable to the one field the test changed.
public sealed class W7eUsageAndCostTests
{
    // ---------------------------------------------------------------------------------------------
    // 1. Usage is recorded once per invocation, and provider/model attribution is correct.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void OneSuccessfulInvocation_WritesExactlyOneLedgerEntry_CarryingItsRoute()
    {
        var path = GovernedPath.Compose(W7eFixture.TwoRoutes(tokensIn: 1_000, tokensOut: 500));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome), "The fixture must produce a successful execution.");
        Assert.Equal(1, path.Model.Count);

        // The alternate was never asked, so the entry below can only be about the primary. Stated
        // because a fixture with two routes and one entry would otherwise be a coincidence rather than
        // an attribution.
        Assert.Equal([W7eFixture.PrimaryModel], path.Model.ModelsAsked);

        // ONE entry, not one per stage and not one per recorded fact. The recorder is the single write
        // site for usage, and this is the count that says so.
        var entries = path.Ledger.Entries();
        Assert.Single(entries);

        var entry = entries[0];

        // Attribution, from the routing outcome rather than from anything the caller said. The caller
        // has no field to name a provider or a model with, so a populated ProviderId here can only
        // have come from the router.
        Assert.Equal(W7eFixture.PrimaryModel, entry.ModelId);
        Assert.Equal(W7eFixture.PrimaryProvider, entry.ProviderId);
        Assert.Equal(AiCapabilities.ChatComplete, entry.Capability.Value);
        Assert.Equal("req-w7d", entry.RequestId);
        Assert.Equal("corr-w7d", entry.CorrelationId);

        // The provider's own measurement, carried through unaltered.
        Assert.Equal(1_000, entry.TokensIn);
        Assert.Equal(500, entry.TokensOut);

        // The route was the primary, not a fallback.
        Assert.False(entry.IsFallback);
    }

    [Fact]
    public void Attribution_JoinsThroughExecutionIdentity_RatherThanADuplicatedRouteField()
    {
        var path = GovernedPath.Compose(W7eFixture.TwoRoutes(tokensIn: 10, tokensOut: 20));

        var outcome = Run(path);
        var entry = path.Ledger.Entries()[0];

        // TASK 11's requirement, stated as a join: the ledger entry's execution identifier is the one
        // the audit record carries, and the provider the execution actually used is recoverable from
        // both. Nothing duplicates the router's selection state — the ledger cites the route it
        // observed and the read model joins the rest.
        Assert.Equal(outcome.AuditReference, entry.ExecutionId);

        var audit = path.Audit.Find(entry.ExecutionId);
        Assert.NotNull(audit);
        Assert.Equal(entry.ProviderId, audit!.ProviderUsed);
        Assert.Equal(entry.ModelId, audit.ModelUsed);
    }

    [Fact]
    public void UsageReadModel_AnswersByCapabilityModelProviderAndCaller()
    {
        var path = GovernedPath.Compose(W7eFixture.TwoRoutes(tokensIn: 100, tokensOut: 40));

        Run(path);

        // Five of the six questions TASK 1 names, each asked as a query rather than by reading a field.
        Assert.Equal(140, path.Ledger.Query(AiUsageQuery.All).TokensIn + path.Ledger.Query(AiUsageQuery.All).TokensOut);

        Assert.Equal(1, path.Ledger.Query(new AiUsageQuery { Capability = CapabilityId.Parse(AiCapabilities.ChatComplete) }).Executions);
        Assert.Equal(0, path.Ledger.Query(new AiUsageQuery { Capability = CapabilityId.Parse(AiCapabilities.DocumentSummarize) }).Executions);

        Assert.Equal(1, path.Ledger.Query(new AiUsageQuery { ModelId = W7eFixture.PrimaryModel }).Executions);
        Assert.Equal(1, path.Ledger.Query(new AiUsageQuery { ProviderId = W7eFixture.PrimaryProvider }).Executions);

        // Caller attribution, where identity is available: the requester the fixture sends is the
        // Product-shaped one, so product and tenant are the ones it declared and nothing else.
        Assert.Equal(1, path.Ledger.Query(new AiUsageQuery { ProductId = "nexus-developer" }).Executions);
        Assert.Equal(1, path.Ledger.Query(new AiUsageQuery { TenantId = "tenant-acme" }).Executions);
        Assert.Equal(0, path.Ledger.Query(new AiUsageQuery { TenantId = "tenant-other" }).Executions);

        // The sixth, asked as a rollup rather than a filter: the same one execution, bucketed by model.
        var byModel = path.Ledger.Query(new AiUsageQuery { GroupBy = AiUsageGroupBy.Model });
        Assert.Single(byModel.Buckets);
        Assert.Equal(W7eFixture.PrimaryModel, byModel.Buckets[0].Key);
    }

    // ---------------------------------------------------------------------------------------------
    // 2. The cost ledger reconciles the prediction against the measurement.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void PricedInvocation_RecordsBothThePredictionAndTheMeasurement()
    {
        var path = GovernedPath.Compose(W7eFixture.Priced(tokensIn: 1_000, tokensOut: 1_000));

        Run(path);

        var entry = path.Ledger.Entries()[0];

        // The rate is 0.50 per thousand in and 1.50 per thousand out, stated in the registry's own
        // metadata. One thousand of each is therefore exactly 2.00 — arithmetic on configured rates and
        // provider-reported tokens, with nothing in the path free to invent a number.
        Assert.Equal(2.00m, entry.ActualCost);
        Assert.Equal("USD", entry.Currency);
        Assert.NotNull(entry.PriceQuoteId);

        // Both numbers are present and they are distinguishable. The prediction is the route's
        // projected cost; the measurement is what the tokens actually cost. The basis says which of
        // the two the ledger is standing behind, and an estate that could not tell them apart would
        // report a prediction as a fact.
        Assert.NotNull(entry.EstimatedCost);
        Assert.Equal(AiCostBasis.ActualRecorded, entry.CostBasis);
    }

    [Fact]
    public void CostTotals_AreDeterministic_AcrossRepeatedRuns()
    {
        static decimal TotalForOneRun()
        {
            var path = GovernedPath.Compose(W7eFixture.Priced(tokensIn: 3_000, tokensOut: 700));
            Run(path);
            return path.Ledger.Query(new AiCostQuery()).TotalCost;
        }

        var first = TotalForOneRun();
        var second = TotalForOneRun();

        // 3 * 0.50 + 0.7 * 1.50 = 1.50 + 1.05 = 2.55, and the same both times. A total that moved
        // between runs would make every budget decision a coin toss.
        Assert.Equal(2.55m, first);
        Assert.Equal(first, second);
    }

    [Fact]
    public void UnpricedInvocation_RecordsTheTokensAndSaysItCannotPriceThem()
    {
        var path = GovernedPath.Compose(new GovernedPathOptions { TokensIn = 900, TokensOut = 100 });

        Run(path);

        var entry = path.Ledger.Entries()[0];

        // NEGATIVE FIXTURE for the cost dimension: this model states no rates. The tokens are still
        // recorded — they are a measurement regardless — and the cost is absent rather than zero. A
        // zero here would be an assertion that the call was free.
        Assert.Equal(900, entry.TokensIn);
        Assert.Equal(100, entry.TokensOut);
        Assert.Null(entry.ActualCost);
        Assert.Equal(AiCostBasis.Unpriced, entry.CostBasis);
    }

    // ---------------------------------------------------------------------------------------------
    // 3. Budget policy is enforced, deterministically, and missing policy is not "unlimited".
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void PricedExecution_UnderACoveringCeiling_RoutesAndSpends()
    {
        var path = GovernedPath.Compose(W7eFixture.PricedSole(
            budget: W7eFixture.Budget(ceiling: 100m)));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome), "A ceiling far above the projected cost must not refuse.");
        Assert.Equal(1, path.Model.Count);
        Assert.Single(path.Ledger.Entries());
    }

    [Fact]
    public void PricedExecution_OverACoveringCeiling_IsRefusedByTheBudgetRule_AndNeverReachesAProvider()
    {
        var path = GovernedPath.Compose(W7eFixture.PricedSole(
            budget: W7eFixture.Budget(ceiling: 0.0001m)));

        var outcome = Run(path);

        // The control above routed the same fixture with a permissive ceiling. This is the same
        // fixture with one field changed, so the refusal is attributable to the ceiling.
        Assert.False(Succeeded(outcome));
        Assert.Equal(0, path.Model.Count);
        Assert.Empty(path.Ledger.Entries());

        // Named, not merely refused. The rejection says which gate produced it and carries the budget
        // decision that did, so an operator reading the outcome is not left guessing whether the
        // refusal was governance, health or money.
        Assert.NotNull(outcome.Routing);
        var budget = Assert.Single(
            outcome.Routing!.OperationalFindings,
            finding => finding.Reason is AiRoutingRejectionReason.BudgetExceeded);

        Assert.NotNull(budget.Budget);
        Assert.Equal("budget.w7e.chat-complete", budget.Budget!.RuleId);
        Assert.True(
            budget.Budget.ProjectedCost > 0.0001m,
            $"The projection must exceed the ceiling, and it was {budget.Budget.ProjectedCost}.");
    }

    [Fact]
    public void PricedExecution_WithNoCoveringRule_Refuses_WhenThatIsTheConfiguredPolicy()
    {
        // The directive's TASK 3: an uncovered priced execution follows the explicitly configured
        // policy, and Refuse is the shipped default. This is the "missing budget does not silently
        // mean unlimited" claim, stated as behaviour rather than as a comment.
        var path = GovernedPath.Compose(W7eFixture.PricedSole(
            budget: new AiOperationsBudgetPolicy
            {
                Rules = [],
                Available = true,
                OnUncoveredPricedExecution = AiBudgetUncoveredBehaviour.Refuse,
            }));

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));
        Assert.Equal(0, path.Model.Count);
        Assert.Empty(path.Ledger.Entries());
    }

    [Fact]
    public void PricedExecution_WithNoCoveringRule_DoesNotRoute_EvenWhenSomeOtherScopeIsBudgeted()
    {
        // NON-VACUITY for the test above: the estate HAS a budget policy and it HAS a rule. The rule
        // covers a different capability, so it does not cover this execution — which is the case a
        // "is any rule configured?" check would wrongly permit.
        var path = GovernedPath.Compose(W7eFixture.PricedSole(
            budget: new AiOperationsBudgetPolicy
            {
                Rules =
                [
                    new AiOperationsBudgetRule
                    {
                        RuleId = "budget.some-other-capability",
                        Capability = CapabilityId.Parse(AiCapabilities.DocumentSummarize),
                        Ceiling = 1_000m,
                        Currency = "USD",
                        Period = AiBudgetPeriod.None,
                        Rationale = "W7E test fixture: a rule that does not cover this execution.",
                    },
                ],
                Available = true,
                OnUncoveredPricedExecution = AiBudgetUncoveredBehaviour.Refuse,
            }));

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));
        Assert.Equal(0, path.Model.Count);
    }

    [Fact]
    public void PricedExecution_WithPolicyNotEvaluated_IsPermitted_WhichIsWhatTheFlagMeans()
    {
        // The control for the two refusals above. `NotEvaluated` is not "no policy" in the sense of an
        // oversight — it is an estate that has said the cost dimension is not part of its policy, and
        // the difference between that and `Refuse`-on-uncovered is the whole point of the field.
        var path = GovernedPath.Compose(
            W7eFixture.PricedSole(budget: AiOperationsBudgetPolicy.NotEvaluated));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));
        Assert.Equal(1, path.Model.Count);
    }

    [Fact]
    public void AnUnpricedExecution_IsNotSubjectToTheBudgetGate_EvenUnderRefuseOnUncovered()
    {
        // The gate is about PRICED execution. A model with no rates has no projection to compare
        // against a ceiling, and refusing it would make the cost policy a ban on unpriced capacity
        // rather than a limit on spend.
        var path = GovernedPath.Compose(W7eFixture.UnpricedSole(
            budget: new AiOperationsBudgetPolicy
            {
                Rules = [],
                Available = true,
                OnUncoveredPricedExecution = AiBudgetUncoveredBehaviour.Refuse,
            }));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));
    }

    [Fact]
    public void ABudgetCeiling_BindsThePricedRouteOnly_AndAnUnpricedAlternateRemainsReachable()
    {
        // The boundary of the budget control, asserted rather than assumed. A ceiling is a limit on
        // SPEND, and the gate can only enforce it against a route whose cost it can compute. An estate
        // whose fallback is unpriced therefore has a route the ceiling does not bound, and the estate
        // routes to it when the priced primary is over budget.
        //
        // This is the shipped semantics, not a defect introduced here: `OnUncoveredPricedExecution`
        // governs priced-and-uncovered execution, and an unpriced execution is out of this dimension's
        // scope entirely. It is recorded because an operator who read a ceiling as a cap on the estate
        // would be wrong, and because the W7F gateway must report the substitution rather than hide it.
        var path = GovernedPath.Compose(W7eFixture.Priced(budget: W7eFixture.Budget(ceiling: 0.0001m)));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));

        // It reached a provider — and specifically not the priced primary it was refused.
        Assert.Equal(W7eFixture.AlternateModel, path.Model.ModelsAsked[^1]);
        Assert.DoesNotContain(W7eFixture.PrimaryModel, path.Model.ModelsAsked);

        // The refusal of the primary is still on the record. The substitution is visible, which is what
        // makes it reviewable.
        Assert.Contains(
            outcome.Routing!.OperationalFindings,
            finding => finding.Reason is AiRoutingRejectionReason.BudgetExceeded);

        Assert.Single(path.Ledger.Entries());
        Assert.Equal(W7eFixture.AlternateProvider, path.Ledger.Entries()[0].ProviderId);
    }
}
