using System.Collections.Generic;
using System.Linq;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Tests.Turns;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Operations;

// W7E TASK 15: the live path, end to end.
//
// THE CHAIN UNDER TEST IS THE DIRECTIVE'S OWN LIST, IN ITS OWN ORDER:
//
//   semantic request -> governed context -> governance -> registry/router
//     -> health/reliability/budget evaluation -> governed provider seam
//     -> usage/cost -> trace/audit
//
// Each test below walks that chain once and asserts at every stage, rather than asserting one stage
// in isolation. The point is not that each stage works - the other suites prove that - but that they
// are actually connected in this order on the one path a request takes, which is the property a
// stage-by-stage suite cannot see.
//
// NO CREDENTIAL IS USED, RESOLVED, READ OR REFERENCED. The provider seam is a recording double and
// every registry entry names the approved secret-reference IDENTIFIER rather than a value. Every
// assertion here holds on a machine where the historical provider credential has never existed.
public sealed class W7eLivePathTests
{
    private const string Internal = "the retry policy is documented in the runbook";
    private const string Restricted = "the vault combination is brass-lantern-nine";

    // ---------------------------------------------------------------------------------------------
    // 1. The successful path, stage by stage.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ASemanticRequest_ReachesAProvider_ThroughEveryStageInOrder()
    {
        var path = GovernedPath.Compose(TwoRoutes(tokensIn: 250, tokensOut: 90));

        var context = GovernedPath.Context(
            GovernedPath.Item("doc.runbook", Internal, DataClassification.Internal),
            GovernedPath.Item("doc.vault", Restricted, DataClassification.Secret));

        // STAGE 1: the semantic request, carrying context the caller did not choose the fate of.
        var outcome = Run(path, GovernedPath.Turn(path.Options, context: context));

        Assert.True(Succeeded(outcome), "The chain must run to completion on a healthy estate.");

        // STAGE 2: governed context. The Internal item was admitted and ranked; the Secret item was
        // not, because the destination the selected route reaches does not admit it. This is the
        // exposure decision, and it ran BEFORE anything was sent.
        Assert.NotNull(outcome.Exposure);
        Assert.Contains(outcome.Context, item => item.Item.Id == "doc.runbook");
        Assert.DoesNotContain(outcome.Context, item => item.Item.Id == "doc.vault");
        Assert.Contains(Internal, path.Model.SentText, System.StringComparison.Ordinal);
        Assert.DoesNotContain(Restricted, path.Model.SentText, System.StringComparison.Ordinal);

        // STAGE 3: governance, on the whole execution.
        Assert.True(outcome.Decision.IsAllowed);
        Assert.NotEmpty(outcome.Decision.RulesApplied);

        // STAGE 4: the registry and the router. The caller named no provider and no model - the
        // request type has no field for either - so the route below can only have come from the
        // registry, ranked by the router.
        Assert.NotNull(outcome.Routing);
        Assert.Equal(AiRoutingStatus.Routed, outcome.Routing!.Status);
        Assert.Equal(PrimaryProvider, outcome.Routing.Selected!.ProviderId);
        Assert.Equal(PrimaryModel, outcome.Routing.Selected.ModelId);

        // STAGE 5: health, reliability and budget, evaluated per candidate. The selected candidate
        // carries the health the snapshot reported for it and an allowing governance decision, and the
        // estate has recorded no operational objection to it.
        Assert.Equal(AiModelHealthState.Available, outcome.Routing.Selected.ModelHealth);
        Assert.Equal(AiModelHealthState.Available, outcome.Routing.Selected.ProviderHealth);
        Assert.True(outcome.Routing.Selected.Governance.IsAllowed);
        Assert.Empty(outcome.Routing.OperationalFindings);

        // STAGE 6: the governed provider seam. Reached exactly once, on the routed model.
        Assert.Equal(1, path.Model.Count);
        Assert.Equal([PrimaryModel], path.Model.ModelsAsked);

        // STAGE 7: usage and cost, written once for the invocation and attributed to the route.
        var entry = Assert.Single(path.Ledger.Entries());
        Assert.Equal(PrimaryModel, entry.ModelId);
        Assert.Equal(PrimaryProvider, entry.ProviderId);
        Assert.Equal(250, entry.TokensIn);
        Assert.Equal(90, entry.TokensOut);

        // STAGE 8: the trace and the audit record. The trace is the narrative; the audit record is the
        // evidence the trace points at.
        Assert.NotEmpty(outcome.Decisions);
        Assert.False(string.IsNullOrWhiteSpace(outcome.AuditReference));

        var audit = path.Audit.Find(outcome.AuditReference!);
        Assert.NotNull(audit);
        Assert.Equal(PrimaryProvider, audit!.ProviderUsed);
        Assert.Equal(PrimaryModel, audit.ModelUsed);
        Assert.Equal(250, audit.Usage.InputTokens);
        Assert.Equal(AiExecutionStatus.Succeeded, audit.Status);

        // ...and the whole thing is answerable from the read surface without reaching into any of the
        // components above.
        var view = path.Operations.Execution(outcome.AuditReference!);
        Assert.NotNull(view);
        Assert.Equal(AiExecutionStatus.Succeeded, view!.Status);
        Assert.Equal(PrimaryModel, view.ModelId);
        Assert.Equal(340, view.TotalTokens);
    }

    [Fact]
    public void AGovernedExecution_LeavesTheReliabilityHistoryKnowingAboutIt()
    {
        // The loop the directive asks for: the operational plane's evidence is produced by the estate's
        // own traffic rather than by an operator's guess, so the reliability gate tightens with use.
        var path = GovernedPath.Compose(TwoRoutes(tokensIn: 10, tokensOut: 5));

        Run(path);

        var evidence = path.Reliability.EvidenceFor(PrimaryProvider, PrimaryModel);

        Assert.Equal(1, evidence.Attempts);
        Assert.Equal(1, evidence.Successes);
        Assert.NotNull(evidence.LastAttemptAt);

        // ...and the operational evidence store carries the routing decision the audit record does not:
        // how many routes were eligible, and which were refused.
        var recorded = path.Operations.Execution(path.Audit.Recent(1)[0].ExecutionId);
        Assert.NotNull(recorded);
        Assert.Equal(2, recorded!.EligibleRoutes);
    }

    // ---------------------------------------------------------------------------------------------
    // 2. The blocked path.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ABlockedRequest_StopsBeforeTheProvider_AndIsStillFullyRecorded()
    {
        var path = GovernedPath.Compose(TwoRoutes(providerApproval: "Suspended"));

        var outcome = Run(path, GovernedPath.Turn(path.Options, context: GovernedPath.Context(
            GovernedPath.Item("doc.runbook", Internal, DataClassification.Internal))));

        // Refused, and refused at the route rather than at the request: the estate had no route it was
        // permitted to use.
        Assert.False(Succeeded(outcome));
        Assert.False(outcome.Decision.IsAllowed);
        Assert.NotNull(outcome.Failure);

        // The provider seam was never reached and nothing was spent.
        Assert.Equal(0, path.Model.Count);
        Assert.Empty(path.Ledger.Entries());

        // The refusal is still an execution, and it is still recorded. This is the record a lane most
        // needs and the one an emitter wired only to the success path would omit.
        Assert.Equal(1, path.Audit.Count);

        var audit = path.Audit.Find(outcome.AuditReference!)!;
        Assert.NotEqual(AiExecutionStatus.Succeeded, audit.Status);
        Assert.Null(audit.ProviderUsed);

        // ...and it is observable, with the reason, without reading any internal state.
        var view = path.Operations.Execution(outcome.AuditReference!)!;
        Assert.False(view.GovernanceAllowed);
        Assert.NotEmpty(view.GovernanceRules);
        Assert.Empty(view.FailoverAttempts);

        // The router's own grounds are on the record too, so an operator can see which gate refused
        // the route rather than only that no route was used.
        var routing = outcome.Routing!;
        Assert.NotEmpty(routing.Rejected);

        // Governance is the only gate that fired on this estate, so each refusal carries the decision
        // that produced it rather than a bare reason code. The pattern is the assertion: it matches a
        // decision that is present AND refusing, so a rejection carrying no decision at all - a route
        // refused by some gate this test did not configure - cannot pass as one governance refused.
        Assert.All(
            routing.Rejected,
            rejection => Assert.True(
                rejection.Governance is { IsAllowed: false },
                $"A refused route must carry the refusing governance decision, and {rejection.ModelId} "
                + $"was refused for {rejection.Reason}."));
    }

    // ---------------------------------------------------------------------------------------------
    // 3. The fallback path.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AFailingPrimary_FailsOver_AndEveryStageRecordsItsPartOfIt()
    {
        var path = GovernedPath.Compose(TwoRoutes(failingModels: [PrimaryModel], tokensIn: 40, tokensOut: 20));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));

        // Two routes were eligible and the request was served by the second - the route the router had
        // already admitted, chosen again at attempt time against live health and cost.
        Assert.Equal(2, outcome.Routing!.Eligible.Count);
        Assert.Equal([PrimaryModel, AlternateModel], path.Model.ModelsAsked);

        var failover = outcome.Failover!;
        Assert.True(failover.UsedFallback);
        Assert.Equal(AiFailoverReasonCode.AlternateSucceeded, failover.ReasonCode);

        // Spend: two calls, two entries, the second attributed to the alternate and flagged.
        var entries = path.Ledger.Entries();
        Assert.Equal(2, entries.Count);
        Assert.Equal(PrimaryProvider, entries[0].ProviderId);
        Assert.False(entries[0].IsFallback);
        Assert.Equal(AlternateProvider, entries[1].ProviderId);
        Assert.True(entries[1].IsFallback);

        // Reliability: both attempts are observed, including the one that failed, which is the evidence
        // the next routing decision will use to skip the route.
        var failed = path.Reliability.EvidenceFor(PrimaryProvider, PrimaryModel);
        Assert.Equal(1, failed.Attempts);
        Assert.Equal(0, failed.Successes);
        Assert.NotNull(failed.LastFailureCategory);

        var served = path.Reliability.EvidenceFor(AlternateProvider, AlternateModel);
        Assert.Equal(1, served.Successes);

        // Audit: the record names the route that served, and the failover decision names the one that
        // did not. Neither is derived from the other.
        var audit = path.Audit.Find(outcome.AuditReference!)!;
        Assert.Equal(AlternateProvider, audit.ProviderUsed);
        Assert.Equal(AlternateModel, audit.ModelUsed);
        Assert.Equal(AiExecutionStatus.Succeeded, audit.Status);

        // Read surface: the substitution is visible rather than hidden behind a success.
        var view = path.Operations.Execution(outcome.AuditReference!)!;
        Assert.True(view.UsedFallback);
        Assert.Equal(AlternateProvider, view.ProviderId);
        Assert.Equal(2, view.FailoverAttempts.Count);

        // Trace: the failover is a step in the narrative, not an inference from the records.
        Assert.Contains(
            outcome.Decisions,
            trace => trace.What.Contains("Failing over", System.StringComparison.OrdinalIgnoreCase));
    }

    // ---------------------------------------------------------------------------------------------
    // 4. The budget-blocked path.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void APricedExecutionOverItsCeiling_IsRefused_AndTheCeilingIsOnTheRecord()
    {
        var path = GovernedPath.Compose(PricedSole(budget: Budget(ceiling: 0.0001m)));

        var outcome = Run(path);

        // The chain stops at the operational gate, before the provider seam and before any spend.
        Assert.False(Succeeded(outcome));
        Assert.Equal(0, path.Model.Count);
        Assert.Empty(path.Ledger.Entries());

        // The refusal names the rule and the projection that exceeded it, rather than reporting a bare
        // "no route". An operator reading it can tell a ceiling from an outage.
        var budget = Assert.Single(
            outcome.Routing!.OperationalFindings,
            finding => finding.Reason is AiRoutingRejectionReason.BudgetExceeded);

        Assert.NotNull(budget.Budget);
        Assert.Equal("budget.w7e.chat-complete", budget.Budget!.RuleId);
        Assert.True(budget.Budget.ProjectedCost > 0.0001m);

        // ...and it survives as far as the read surface an operator actually uses: the ceiling that
        // refused it, by rule, on the execution's own view rather than only on the router's return
        // value. An operator reading a blocked execution must be able to tell a ceiling from an outage
        // without reconstructing the routing decision.
        var view = path.Operations.Execution(outcome.AuditReference!)!;
        Assert.Equal(AiGovernanceVerdict.Block, view.BudgetVerdict);
        Assert.Equal("budget.w7e.chat-complete", view.BudgetRuleId);
        Assert.Equal(AiExecutionStatus.Blocked, view.Status);

        // ...and the two planes are reported separately, which is what makes the refusal actionable.
        // Governance PERMITTED this execution - the capability, the classification and the requester are
        // all acceptable - and the ceiling is the only thing that stopped it. An operator reading this
        // is being told to look at the budget, not at policy, and a view that collapsed the two would
        // send them to the wrong one.
        Assert.True(view.GovernanceAllowed);
        Assert.NotEmpty(view.GovernanceRules);

        // The refusal is still an execution and is still recorded.
        Assert.Equal(1, path.Audit.Count);
    }

    [Fact]
    public void AServedExecution_WhoseSiblingRouteWasRefusedByACeiling_IsNotReportedAsBlocked()
    {
        // CONTROL for the refusal above, and the reason the read model reads a refused execution's
        // ceiling from the finding rather than always from the selected candidate's verdict.
        //
        // Here the priced primary is refused by the same ceiling and an unpriced alternate serves the
        // request. The execution succeeded, so its budget verdict must say nothing about the ceiling
        // that refused the route it did not use — reporting Block here would tell an operator that a
        // completed execution was blocked by a budget.
        var path = GovernedPath.Compose(Priced(budget: Budget(ceiling: 0.0001m)));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));

        // The refusal really happened, and really is on the record - otherwise this control would pass
        // on an estate where nothing was refused and prove nothing.
        Assert.Contains(
            outcome.Routing!.OperationalFindings,
            finding => finding.Reason is AiRoutingRejectionReason.BudgetExceeded);

        var view = path.Operations.Execution(outcome.AuditReference!)!;
        Assert.NotEqual(AiGovernanceVerdict.Block, view.BudgetVerdict);
        Assert.Equal(AiExecutionStatus.Succeeded, view.Status);
    }

    [Fact]
    public void TheSamePricedExecution_UnderACoveringCeiling_Runs_WhichIsWhatMakesItEvidence()
    {
        // CONTROL for the refusal above: one field changed, the ceiling. Same estate, same model, same
        // rates, same projection - and the execution completes.
        var path = GovernedPath.Compose(PricedSole(budget: Budget(ceiling: 100m)));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));
        Assert.Equal(1, path.Model.Count);
        Assert.Single(path.Ledger.Entries());

        var view = path.Operations.Execution(outcome.AuditReference!)!;
        Assert.NotEqual(AiGovernanceVerdict.Block, view.BudgetVerdict);
    }

    // ---------------------------------------------------------------------------------------------
    // 5. The whole chain is deterministic.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TwoIdenticalRuns_ProduceIdenticalRecords()
    {
        // TASK 14's "cost totals are deterministic" and its wider claim: a routing decision is
        // reproducible from the state it read. Two runs over the same estate produce the same route,
        // the same tokens, the same cost and the same status - so a budget decision is not a coin toss.
        static (string Model, int? TokensIn, decimal? Cost, AiExecutionStatus Status) Once()
        {
            var path = GovernedPath.Compose(Priced(tokensIn: 3_000, tokensOut: 700));
            var outcome = Run(path, "req-w7e-determinism");

            var entry = path.Ledger.Entries()[0];

            return (entry.ModelId, entry.TokensIn, entry.ActualCost, path.Audit.Find(outcome.AuditReference!)!.Status);
        }

        var first = Once();
        var second = Once();

        Assert.Equal(first, second);
        Assert.Equal(2.55m, first.Cost);
    }
}
