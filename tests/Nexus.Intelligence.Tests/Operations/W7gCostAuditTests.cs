using System;
using System.Collections.Generic;
using System.Linq;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Tests.Turns;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Operations;

// W7G-R TASK 6: the cost-and-audit proof, over a failover sequence and over a recovery probe.
//
// WHAT THIS FILE ADDS. W7gFailoverTests section D already proves that a failover leaves its attempts,
// its usage and its cost on the record. What it does not reach is the part of the directive's eleven
// items that only a PRICED execution with a budget policy can carry - the budget verdict on the route
// that served, the verdict on the route held in reserve, the rule that produced it - and the circuit
// and reliability state, which no failover test seeds. Nor does anything in the estate assert
// AiExecutionOperationsView.IsProbe, the member that tells an operator whether a call was ordinary
// capacity or probationary traffic.
//
// So the two tests here are assembled as item-labelled sequences rather than as one property per test,
// following W7gRecoveryTests' shape: the directive names eleven facts about ONE record, and the proof
// that answers it is a walk through that record. Where an item is proved somewhere else, the test says
// so rather than restating it, and W7G_COST_AUDIT.md carries the index.
//
// Every figure is asserted exactly. A cost claim that can only be stated as a range is not a cost
// claim, and the rates were chosen so the arithmetic is checkable at a glance.
public sealed class W7gCostAuditTests
{
    /// <summary>The caller's request identifier, constant across everything asserted about it.</summary>
    private const string RequestId = "req-w7g-cost-audit";

    /// <summary>
    /// A priced failover, walked item by item through the surface an operator actually reads.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The estate: two priced routes, the primary cheaper (1.60 for this work) than the alternate
    /// (2.00), the primary declared failing, and a daily ceiling of 1.70 that covers each route's own
    /// projection but not both. The primary is the cheaper route deliberately - the router's cost term
    /// makes a cheaper route outrank a dearer one, so pricing the alternate below the primary inverts
    /// the chain and turns a failover test into a test of a healthy primary.
    /// </para>
    /// <para>
    /// The record is read back through <see cref="IAiOperationsReadModel.Execution"/>, never through
    /// the decision object the governed path was holding. A fact that only exists in memory answers a
    /// question nobody outside the request can ask.
    /// </para>
    /// </remarks>
    [Fact]
    public void AFailoverSequence_CarriesEveryItemTheCostAndAuditProofNames()
    {
        var path = GovernedPath.Compose(PricedBoth(
            budget: Budget(1.70m, period: AiBudgetPeriod.Daily),
            failingModels: [PrimaryModel],
            reliability: AiReliabilityPolicy.Default,
            history: [.. HealthyHistoryFor(PrimaryModel)]));

        Assert.True(Succeeded(Run(path, RequestId)));

        var entries = path.Ledger.Entries();
        Assert.Equal(2, entries.Count);

        var executionId = Assert.Single(entries.Select(entry => entry.ExecutionId).Distinct());
        var view = path.Operations.Execution(executionId);

        Assert.NotNull(view);
        var audit = view!;

        // ITEM 7 — the caller's request identifier, echoed onto the execution record and distinct
        // from the estate's own identity for the execution. The caller correlates by the first and
        // resolves evidence by the second; a record that carried only one would leave a caller able
        // to do one of the two.
        Assert.Equal(RequestId, audit.RequestId);

        // ITEM 8 — one execution, two attempts, and the two identities are not the caller's. The
        // execution identifier is asserted to be ONE value across both ledger entries rather than to
        // be one entry: a failover that minted a second execution identity would make the spend
        // unsummable and the audit record unjoinable.
        Assert.NotEqual(RequestId, executionId);
        Assert.Equal(2, entries.Select(entry => entry.AttemptId).Distinct().Count());
        Assert.All(entries, entry => Assert.NotEqual(RequestId, entry.AttemptId));

        // ITEM 1 — the budget and cost decision on the INITIAL candidate. Reaching a verdict at all
        // requires a priced execution and a covering rule, which is why this is asserted here and not
        // in the failover suite: with no budget policy the gate reaches no verdict, and null is not an
        // allow.
        Assert.NotNull(audit.BudgetVerdict);
        Assert.True(audit.BudgetVerdict is AiGovernanceVerdict.Allow);
        Assert.Equal("budget.w7e.chat-complete", audit.BudgetRuleId);
        Assert.NotNull(audit.Budget);
        Assert.Equal(AiBudgetOutcome.WithinCeiling, audit.Budget!.Outcome);
        Assert.Equal(AiBudgetPeriod.Daily, audit.Budget.Period);
        Assert.Equal("USD", audit.Budget.Currency);

        // ITEM 2 — why each candidate went the way it did, per attempt and in order. The primary was
        // invoked and failed, so its cause is the failure rather than a refusal; the rejection
        // EVIDENCE for a candidate that was refused before invocation is proved in W7gFailoverTests
        // sections A, B and C, where six refusals carry their own codes and payloads.
        Assert.Equal(2, audit.FailoverAttempts.Count);

        var primary = Assert.Single(audit.FailoverAttempts, attempt => attempt.ModelId == PrimaryModel);
        Assert.Equal(0, primary.Order);
        Assert.Equal(AiFailoverAttemptOutcome.Attempted, primary.Outcome);
        Assert.Contains(AiFailureCategory.ProviderUnavailable.ToString(), primary.Detail, StringComparison.Ordinal);
        Assert.False(string.IsNullOrWhiteSpace(primary.Detail));

        // ITEM 3 — the budget and cost decision on the FALLBACK, read from the attempt the fallback
        // selected. This is the half that says the alternate was affordable when it was chosen, not
        // merely that it was chosen: an estate that failed over onto a route it had never priced
        // would be reported here as an unpriced decision rather than as an allowed one.
        var alternate = Assert.Single(audit.FailoverAttempts, attempt => attempt.ModelId == AlternateModel);
        Assert.Equal(1, alternate.Order);
        Assert.Equal(AiFailoverAttemptOutcome.AlternateSucceeded, alternate.Outcome);
        Assert.NotNull(alternate.Budget);
        Assert.Equal(AiBudgetOutcome.WithinCeiling, alternate.Budget!.Outcome);
        Assert.Equal("budget.w7e.chat-complete", alternate.Budget.RuleId);

        // ITEM 4 — the provider and model that ACTUALLY served, on the record, as operator facts.
        // These are precisely the two fields the caller-facing contract withholds.
        Assert.Equal(AlternateProvider, audit.ProviderId);
        Assert.Equal(AlternateModel, audit.ModelId);
        Assert.True(audit.UsedFallback);

        // ITEM 5 — usage, counted over every provider call the execution made rather than over the
        // surviving one. Both attempts reported a thousand in and a thousand out, so the execution's
        // figures are the sum; a record that kept only the fallback's usage would report half.
        Assert.Equal(2_000, audit.TokensIn);
        Assert.Equal(2_000, audit.TokensOut);
        Assert.Equal(4_000, audit.TotalTokens);

        // ITEM 6 — the cost and the BASIS it rests on. 1.60 measured on the failed attempt plus 2.00
        // measured on the served one, both derived from what each provider reported rather than from
        // a prediction. The prediction is kept as well and is allowed to differ: the router sizes this
        // fixture's work at a couple of tokens, and the disagreement between the two is the fact an
        // operator reconciling a bill needs.
        Assert.Equal(3.60m, audit.Cost);
        Assert.Equal(AiCostBasis.ActualRecorded, audit.CostBasis);
        Assert.Equal("USD", audit.Currency);

        var served = Assert.Single(entries, entry => entry.IsFallback);
        Assert.Equal(2.00m, served.ActualCost);
        Assert.Equal(AiCostBasis.ActualRecorded, served.CostBasis);
        Assert.Equal(2.00m, served.AuthoritativeCost);
        Assert.NotNull(served.EstimatedCost);
        Assert.NotEqual(served.ActualCost, served.EstimatedCost);
        Assert.NotNull(served.PriceQuoteId);

        // ITEM 9 — the circuit and reliability state the recovery gate read, carried whole rather
        // than flattened. The estate seeds four successes and one failure behind the primary, so the
        // state is Degraded rather than Healthy and the reading is FailureObserved: a circuit that has
        // seen a failure while still above its floor. That is the more informative of the two states
        // to pin, because it is the one that says "usable, and not unscathed" — Open would refuse the
        // route, Healthy would hide the failure, and the record distinguishes all three.
        Assert.NotNull(audit.Circuit);
        Assert.Equal(AiCircuitState.Degraded, audit.Circuit!.State);
        Assert.Equal(AiCircuitStateChangeReason.FailureObserved, audit.Circuit.Reason);
        Assert.True(audit.Circuit.IsEligible);
        Assert.False(audit.Circuit.IsProbePermitted);

        // WHICH ROUTE'S STATE THIS IS, because the answer is not the one the surrounding members
        // suggest and an operator reading one record needs to know it. The execution-level circuit is
        // the ROUTER's selected route's — the primary — evidenced here by the sample size, which is
        // exactly the history seeded for the primary and nothing else. The members beside it
        // (ProviderId, ModelId) name the route that SERVED, which after a failover is the alternate.
        // Both are facts about this execution and the view is a blend of them; see W7G_COST_AUDIT F-5.
        Assert.Equal(5, audit.Circuit.AttemptsObserved);
        Assert.Equal(1, audit.Circuit.FailuresObserved);
        Assert.NotEqual(PrimaryModel, audit.ModelId);
        Assert.False(audit.IsProbe);

        // The reliability evidence behind each attempt, at the moment of the decision. The alternate
        // carries its own because the selector re-evaluated it before using it; the primary carries
        // none because the selector never saw it — it was the router's choice, not the selector's, and
        // its evidence is the execution-level circuit above. Asserting the absence as well as the
        // presence is what makes this a statement about where the evidence lives rather than about
        // which assertion happened to pass.
        Assert.NotNull(alternate.Reliability);
        Assert.Null(primary.Reliability);

        // ITEM 10 — the governance verdict, both on the execution and on each route that ran. The
        // per-attempt decisions are the ones that answer "who permitted THIS call"; before W7G-R the
        // invoked branch carried none, so a fallback's call could not be traced to a verdict.
        Assert.True(audit.GovernanceAllowed);
        Assert.NotEmpty(audit.GovernanceRules);
        Assert.NotNull(primary.Governance);
        Assert.True(primary.Governance!.IsAllowed);
        Assert.NotNull(alternate.Governance);
        Assert.True(alternate.Governance!.IsAllowed);

        // ITEM 11 — the final outcome, as the estate recorded it.
        Assert.Equal(AiExecutionStatus.Succeeded, audit.Status);
        Assert.Equal(AiFailoverReasonCode.AlternateSucceeded, audit.FailoverReasonCode);
        Assert.Null(audit.FailureCategory);

        // And the boundary this proof is bound by: no secret material. The credential freedom of
        // these types is a TYPE-level property asserted by reflection over the whole Contracts
        // assembly (W7a1CredentialIsolationTests.Contracts_CarryNoSecretValuedMember, with its own
        // control arm); what is asserted here is the runtime half - the rendered record carries no
        // credential-shaped value, and the fields that name a provider are identifiers.
        var rendered = audit.ToString();

        Assert.DoesNotContain("apiKey", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("password", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("clientSecret", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("privateKey", rendered, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// A recovery probe is marked as a probe on its own record, and ordinary traffic is not.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>The directive's "routing may send only explicitly permitted probe traffic while HALF_OPEN"
    /// has two halves: that the estate sends a bounded probe, and that the probe is identifiable
    /// afterwards.</b> The first is proved in W7gRecoveryTests, where the allowance is measured as a
    /// provider call count. The second is this test, and it matters for a reason the first cannot
    /// cover: spend, latency and failure rate all change when probationary traffic starts, and an
    /// operator who cannot separate a probe's spend from ordinary capacity's cannot tell a recovering
    /// route from a busy one. <see cref="AiExecutionOperationsView.IsProbe"/> is never asserted
    /// anywhere else in the estate.
    /// </para>
    /// <para>
    /// The estate is one route with three recorded failures behind it, dated far enough back that the
    /// configured cooldown has elapsed with nothing in between to observe - which is the ordinary case
    /// the breaker's own remarks describe: a circuit opens, the estate stops calling, time passes. The
    /// route is therefore HALF_OPEN with its allowance unspent, and the call the estate makes is the
    /// probe.
    /// </para>
    /// </remarks>
    [Fact]
    public void AProbeExecution_IsMarkedAsAProbe_AndOrdinaryTrafficIsNot()
    {
        var opened = DateTimeOffset.UtcNow - TimeSpan.FromMinutes(10);

        var path = GovernedPath.Compose(SolePricedRoute(
            history:
            [
                Failure(opened),
                Failure(opened + TimeSpan.FromMinutes(1)),
                Failure(opened + TimeSpan.FromMinutes(2)),
            ]));

        Assert.True(Succeeded(Run(path, RequestId)));

        var executionId = Assert.Single(path.Ledger.Entries().Select(entry => entry.ExecutionId).Distinct());
        var audit = path.Operations.Execution(executionId);

        Assert.NotNull(audit);

        // WHAT WAS PERMITTED — the route was HALF_OPEN, its cooldown had elapsed, and exactly one
        // probe was available. Asserted on the record, which is where an operator reads it.
        Assert.NotNull(audit!.Circuit);
        Assert.Equal(AiCircuitState.HalfOpen, audit.Circuit!.State);
        Assert.Equal(AiCircuitStateChangeReason.CooldownElapsed, audit.Circuit.Reason);
        Assert.True(audit.Circuit.CooldownElapsed);
        Assert.Equal(1, audit.Circuit.ProbeAllowance);
        Assert.Equal(0, audit.Circuit.ProbeAttempts);
        Assert.True(audit.Circuit.IsProbePermitted);
        Assert.False(audit.Circuit.IsEligible);

        // WHAT WAS DONE — the call is marked as probationary traffic rather than as ordinary
        // capacity, on the same record that reports the state that permitted it.
        Assert.True(
            audit.IsProbe,
            "a call made under a HALF_OPEN circuit is a probe, and the record must say so");

        // And the failures that opened the circuit are still on the record that reports the probe.
        // A recovery implemented by forgetting would report zero here while looking identical
        // everywhere above.
        Assert.Equal(3, audit.Circuit.AttemptsObserved);
        Assert.Equal(3, audit.Circuit.FailuresObserved);
        Assert.NotNull(audit.Circuit.OpenedAt);

        // CONTROL: the identical estate with no recorded history. The route is Healthy, eligible,
        // and the call is ordinary capacity - so the true above is the circuit state being read
        // rather than a member that answers true unconditionally.
        var ordinary = GovernedPath.Compose(SolePricedRoute(history: []));

        Assert.True(Succeeded(Run(ordinary, RequestId)));

        var ordinaryId = Assert.Single(ordinary.Ledger.Entries().Select(entry => entry.ExecutionId).Distinct());
        var ordinaryAudit = ordinary.Operations.Execution(ordinaryId);

        Assert.NotNull(ordinaryAudit);
        Assert.False(ordinaryAudit!.IsProbe);
        Assert.True(ordinaryAudit.Circuit!.IsEligible);
        Assert.False(ordinaryAudit.Circuit.IsProbePermitted);
        Assert.Equal(AiCircuitState.Healthy, ordinaryAudit.Circuit.State);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    /// <summary>One priced route and nothing else, so a probe cannot be outranked by a healthy peer.</summary>
    /// <remarks>
    /// A second route would be Healthy with no history, and the router would prefer it to a route
    /// carrying a HALF_OPEN circuit - correctly, and in a way that would make the probe test pass or
    /// fail for a reason it did not name. One route makes the circuit state the only thing that can
    /// decide.
    /// </remarks>
    private static GovernedPathOptions SolePricedRoute(IReadOnlyList<AiReliabilityAttempt> history) => new()
    {
        Providers = [Route(PrimaryProvider, priority: 10)],
        Models = [ModelFor(PrimaryModel, PrimaryProvider, inputRate: 0.50m, outputRate: 1.50m)],
        Reliability = AiReliabilityPolicy.Default,
        History = [.. history],
        TokensIn = 1_000,
        TokensOut = 1_000,
    };

    /// <summary>
    /// Five attempts for a route with four of them successful, so its circuit stays closed.
    /// </summary>
    /// <remarks>
    /// The rate is deliberately above the floor and the run of failures shorter than the ceiling, so
    /// this evidence is present on the record without opening anything. A fixture whose seeded history
    /// opened the circuit would make the failover test a probe test, which is the next test's subject.
    /// </remarks>
    private static IEnumerable<AiReliabilityAttempt> HealthyHistoryFor(string modelId)
    {
        var at = DateTimeOffset.UtcNow - TimeSpan.FromHours(1);

        yield return Success(modelId, at);
        yield return Success(modelId, at + TimeSpan.FromMinutes(1));
        yield return Success(modelId, at + TimeSpan.FromMinutes(2));
        yield return Success(modelId, at + TimeSpan.FromMinutes(3));
        yield return Failure(at + TimeSpan.FromMinutes(4));
    }

    private static AiReliabilityAttempt Success(string modelId, DateTimeOffset at) => new()
    {
        ProviderId = PrimaryProvider,
        ModelId = modelId,
        Succeeded = true,
        At = at,
    };

    private static AiReliabilityAttempt Failure(DateTimeOffset at) => new()
    {
        ProviderId = PrimaryProvider,
        ModelId = PrimaryModel,
        Succeeded = false,
        FailureCategory = AiFailureCategory.ProviderUnavailable,
        At = at,
    };
}
