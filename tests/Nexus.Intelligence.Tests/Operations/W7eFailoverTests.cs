using System.Linq;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Tests.Turns;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Operations;

// W7E TASK 7: failover, operationalized over live health, reliability, budget and governance.
//
// THE PROPERTY UNDER TEST IS NOT "A FALLBACK HAPPENS". It is that a fallback happens only where
// governance already said the route was permitted for this exact request, and that every route the
// selector considered is on the record with the reason it was used or refused. A suite that only
// asserted "the alternate served the request" would pass on a selector that reached any route it
// liked, which is the failure mode the whole lane exists to prevent.
//
// WHY FIXTURES FAIL THE PRIMARY BY MODEL RATHER THAN BY HEALTH. Health is read by the router as well
// as the selector, so an unhealthy primary never enters the chain in the first place - which tests a
// different thing. The recording seam fails a NAMED MODEL at invocation time, so the primary is
// routed to, fails, and the failover is what has to respond. That is the sequence TASK 7 describes.
public sealed class W7eFailoverTests
{
    // ---------------------------------------------------------------------------------------------
    // 1. A healthy primary is not a failover.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AHealthyPrimary_IsUsed_AndNoAlternateIsSought()
    {
        var path = GovernedPath.Compose(TwoRoutes());

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));
        Assert.Equal([PrimaryModel], path.Model.ModelsAsked);

        // The failover plane ran and concluded there was nothing to do. It reports a one-step decision
        // rather than no decision, so "no failover happened" and "the failover plane did not run" stay
        // distinguishable - and a null here would be the second fact, not this one.
        Assert.NotNull(outcome.Failover);
        Assert.False(outcome.Failover!.UsedFallback);
        Assert.Equal(PrimaryModel, outcome.Failover.Selected!.ModelId);
        Assert.Equal(AiFailoverReasonCode.HealthyRoute, outcome.Failover.ReasonCode);
        Assert.False(outcome.Failover.AttemptedAlternate);

        // One attempt, on the primary, which succeeded. A chain that had been walked would show more.
        var only = Assert.Single(outcome.Failover.Attempts);
        Assert.Equal(AiFailoverAttemptOutcome.PrimarySucceeded, only.Outcome);
        Assert.True(only.Governance!.IsAllowed);
    }

    // ---------------------------------------------------------------------------------------------
    // 2. A failing primary fails over to a route governance already permitted.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AFailedPrimary_FailsOver_AndTheAlternateServes()
    {
        var path = GovernedPath.Compose(TwoRoutes(failingModels: [PrimaryModel]));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome), "The alternate must complete the request the primary could not.");

        // Both were asked, in that order: the primary was attempted and failed, and the failover moved
        // on. A count of one would mean the failover never happened.
        Assert.Equal([PrimaryModel, AlternateModel], path.Model.ModelsAsked);

        var failover = outcome.Failover;
        Assert.NotNull(failover);
        Assert.True(failover!.UsedFallback);
        Assert.Equal(AlternateModel, failover.Selected!.ModelId);
        Assert.Equal(AiFailoverReasonCode.AlternateSucceeded, failover.ReasonCode);

        // The selected route carries the governance decision the ROUTER made for this request. A
        // candidate without one would be a route reached without a verdict, which is the property the
        // selector's shape exists to make impossible - asserted here rather than assumed.
        Assert.True(failover.Selected.Governance.IsAllowed);

        // And it is attributable: the failed attempt and the successful one are both on the record,
        // each against its own route.
        Assert.Equal(2, failover.Attempts.Count);
        Assert.Contains(failover.Attempts, attempt =>
            attempt.ModelId == PrimaryModel && attempt.Outcome is AiFailoverAttemptOutcome.Attempted);
        Assert.Contains(failover.Attempts, attempt =>
            attempt.ModelId == AlternateModel
            && attempt.Outcome is AiFailoverAttemptOutcome.AlternateSucceeded);
    }

    [Fact]
    public void TheFallbackInvocation_IsAttributedToTheFallbackRoute_InTheLedger()
    {
        var path = GovernedPath.Compose(TwoRoutes(failingModels: [PrimaryModel], tokensIn: 7, tokensOut: 3));

        Run(path);

        var entries = path.Ledger.Entries();

        // Two provider calls, two entries - the failed attempt is a call the estate paid for and is
        // recorded as one. A ledger that only recorded successes would under-report exactly the traffic
        // that failover produces.
        Assert.Equal(2, entries.Count);

        var failed = entries[0];
        var served = entries[1];

        Assert.Equal(PrimaryProvider, failed.ProviderId);
        Assert.False(failed.IsFallback);

        Assert.Equal(AlternateProvider, served.ProviderId);
        Assert.Equal(AlternateModel, served.ModelId);

        // The fallback flag is what makes the two separable after the fact, and it is the field an
        // operations surface alerts a spend or latency change on.
        Assert.True(served.IsFallback);
    }

    // ---------------------------------------------------------------------------------------------
    // 3. A route governance refuses is never reachable as a fallback.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AnAlternateGovernanceRefused_IsNeverInTheChain_AndIsNeverReached()
    {
        // The alternate exists, is registered, is enabled, is healthy and is priced. The only thing
        // wrong with it is that its approval was suspended - a governance fact, not an operational one.
        // A fallback plane that did its own availability reasoning would use it.
        var path = GovernedPath.Compose(SuspendedAlternate());

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));

        // It was never called. This is the assertion the whole section exists for.
        Assert.Equal([PrimaryModel], path.Model.ModelsAsked);

        // And the reason is on the record rather than incidental: the router rejected the candidate by
        // governance before it could enter the chain, so the chain the selector walks is empty and the
        // operator can see which gate produced the outcome.
        Assert.NotNull(outcome.Routing);
        Assert.Empty(outcome.Routing!.FallbackChain);

        var rejected = Assert.Single(
            outcome.Routing.Rejected,
            rejection => rejection.ModelId == AlternateModel);

        Assert.Equal(AiRoutingRejectionReason.GovernanceBlocked, rejected.Reason);

        Assert.NotNull(outcome.Failover);
        Assert.Equal(AiFailoverReasonCode.NoHealthyAlternate, outcome.Failover!.ReasonCode);
        Assert.False(outcome.Failover.UsedFallback);
    }

    [Fact]
    public void TheSameEstate_WithTheAlternateApproved_FailsOver_WhichIsWhatMakesItEvidence()
    {
        // CONTROL. One field changed - the alternate's approval - and the outcome inverts: the chain is
        // non-empty and the fallback serves. Without this, the test above would also pass on a fixture
        // whose alternate simply was not reachable for an unrelated reason.
        var path = GovernedPath.Compose(TwoRoutes(failingModels: [PrimaryModel]));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));
        Assert.Single(outcome.Routing!.FallbackChain);
        Assert.Equal([PrimaryModel, AlternateModel], path.Model.ModelsAsked);
    }

    [Fact]
    public void TheFallbackChain_IsASliceOfTheGovernedEligibleSet()
    {
        // The structural half, asserted on the shape rather than taken on trust: every member of the
        // chain is a member of the eligible set, and every eligible candidate carries an allowing
        // governance decision. The chain therefore cannot contain a route governance did not permit
        // for this request, classification and destination.
        var path = GovernedPath.Compose(TwoRoutes());

        var outcome = Run(path);

        var routing = outcome.Routing!;

        Assert.NotEmpty(routing.Eligible);
        Assert.All(routing.Eligible, candidate => Assert.True(candidate.Governance.IsAllowed));

        Assert.All(routing.FallbackChain, candidate =>
            Assert.Contains(
                routing.Eligible,
                eligible => eligible.ModelId == candidate.ModelId
                    && eligible.ProviderId == candidate.ProviderId));

        // The selected route is the first eligible one, and it is not a fallback - so the chain is a
        // suffix of the eligible set rather than an independently assembled list.
        Assert.Equal(routing.Eligible[0].ModelId, routing.Selected!.ModelId);
        Assert.Equal([AlternateModel], routing.FallbackChain.Select(candidate => candidate.ModelId));
    }

    // ---------------------------------------------------------------------------------------------
    // 4. Depth, and what happens when it runs out.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AFallbackDepthOfZero_LeavesAFailingPrimaryWithNowhereToGo()
    {
        // The configured depth is a ceiling on how far the estate will go, not a hint. With it at zero
        // a failing primary is an execution failure even though a perfectly good alternate is standing
        // by, because the estate said not to use one.
        var path = GovernedPath.Compose(TwoRoutes(failingModels: [PrimaryModel], fallbackDepth: 0));

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));
        Assert.Equal([PrimaryModel], path.Model.ModelsAsked);
        Assert.Empty(outcome.Routing!.FallbackChain);

        Assert.NotNull(outcome.Failover);
        Assert.Equal(AiFailoverReasonCode.NoHealthyAlternate, outcome.Failover!.ReasonCode);
    }

    [Fact]
    public void TheSameEstate_WithADepthOfOne_FailsOver_WhichIsWhatMakesItEvidence()
    {
        // CONTROL: one field changed, the configured depth.
        var path = GovernedPath.Compose(TwoRoutes(failingModels: [PrimaryModel], fallbackDepth: 1));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));
        Assert.Equal([PrimaryModel, AlternateModel], path.Model.ModelsAsked);
    }

    [Fact]
    public void WhenEveryRouteFails_TheExecutionFails_AndNothingIsInventedToServeIt()
    {
        var path = GovernedPath.Compose(
            TwoRoutes(failingModels: [PrimaryModel, AlternateModel], fallbackDepth: 1));

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));

        // Both configured routes were tried and neither worked. The estate reports the failure rather
        // than continuing to search, and it does not substitute a route that was not configured.
        Assert.Equal([PrimaryModel, AlternateModel], path.Model.ModelsAsked);

        Assert.NotNull(outcome.Failover);
        var failover = outcome.Failover!;

        Assert.False(failover.UsedFallback);
        Assert.Null(failover.Selected);
        Assert.Equal(AiFailoverReasonCode.FallbackDepthExhausted, failover.ReasonCode);

        // The terminal reason is why it stopped; the step reasons are why each route went the way it
        // did. Both are present, which is what makes the sequence reconstructable after the fact.
        Assert.Equal(2, failover.Attempts.Count);
        Assert.All(failover.Attempts, attempt =>
            Assert.Equal(AiFailoverAttemptOutcome.Attempted, attempt.Outcome));

        // The failure is typed and observable rather than a bare exception.
        Assert.NotNull(outcome.Failure);
    }

    // ---------------------------------------------------------------------------------------------
    // 5. Refusals are not failures, and are not routed around.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AGovernanceRefusalAtRouting_ReachesNoProvider_AndOffersNoAlternate()
    {
        // Both routes are suspended, so governance refuses the capability before a candidate is
        // selected. The estate must not treat that as an absence of capacity and start searching for
        // something that will do the work anyway - that is using failover to obtain work policy
        // declined to permit.
        var path = GovernedPath.Compose(TwoRoutes(providerApproval: "Suspended"));

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));

        // Nothing reached a provider at all, on either route.
        Assert.Empty(path.Model.ModelsAsked);
        Assert.Empty(path.Ledger.Entries());

        // And there is no failover record, because the operational plane never ran: routing refused
        // before an invocation existed to fail. That null is a fact about how far the execution got,
        // which is exactly what the "present-and-not-needed" record above exists to keep distinct.
        Assert.Null(outcome.Failover);
        Assert.NotNull(outcome.Failure);
    }

    [Fact]
    public void TheSelector_StopsOnAGovernanceFailure_AndOffersNoCandidate()
    {
        // TASK 7's central claim, asserted where it is decided rather than only where it is observed.
        // The router admitted a perfectly usable alternate - it is in the chain below - and the failure
        // being failed over from is a policy refusal. The selector must stop anyway: the chain exists to
        // survive operational failures, never to find a route that will do refused work.
        var path = GovernedPath.Compose(TwoRoutes());
        var routing = Run(path).Routing!;

        Assert.NotEmpty(routing.FallbackChain);

        var step = Selector(path).Next(
            Request(),
            new AiRoutingContext(),
            routing,
            [],
            AiFailure.From(
                AiFailureCategory.PolicyBlocked,
                "governance.policy-blocked",
                "W7E test fixture: a governance refusal, not an operational failure.",
                "corr-w7e"),
            DateTimeOffset.UtcNow);

        Assert.False(step.HasCandidate);
        Assert.Equal(AiFailoverReasonCode.GovernanceBlockNotFailover, step.ReasonCode);
        Assert.Empty(step.Skipped);
    }

    [Fact]
    public void TheSameChain_WithAnOperationalFailure_OffersTheAlternate_WhichIsWhatMakesItEvidence()
    {
        // CONTROL: the same estate, the same chain, the same selector. One field changed - the failure's
        // category - and the selector moves. Without this, the refusal above would also pass on a
        // selector that never offered a candidate to anyone.
        var path = GovernedPath.Compose(TwoRoutes());
        var routing = Run(path).Routing!;

        var step = Selector(path).Next(
            Request(),
            new AiRoutingContext(),
            routing,
            [],
            AiFailure.From(
                AiFailureCategory.ProviderUnavailable,
                "provider.unavailable",
                "W7E test fixture: an operational failure.",
                "corr-w7e"),
            DateTimeOffset.UtcNow);

        Assert.True(step.HasCandidate);
        Assert.Equal(AiFailoverReasonCode.AttemptingAlternate, step.ReasonCode);
        Assert.Equal(AlternateModel, step.Candidate!.ModelId);

        // The candidate it offers carries the router's own allowing decision, which is the reason the
        // chain is a safe source of routes: it is a slice of what governance already permitted.
        Assert.True(step.Candidate.Governance.IsAllowed);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    /// <summary>The two-route estate with the alternate's governance approval suspended.</summary>
    /// <remarks>
    /// Everything else about the alternate is left exactly as the healthy fixture has it - enabled,
    /// registered, declared Available, unpriced - so the only difference between this estate and the
    /// control is the approval, and the refusal is attributable to it.
    /// </remarks>
    private static GovernedPathOptions SuspendedAlternate() => new()
    {
        Providers =
        [
            GovernedPath.ProviderEntry(PrimaryProvider, priority: 10),
            GovernedPath.ProviderEntry(AlternateProvider, priority: 5, approval: "Suspended"),
        ],
        Models =
        [
            GovernedPath.ModelEntry(PrimaryModel, PrimaryProvider),
            GovernedPath.ModelEntry(AlternateModel, AlternateProvider, approval: "Suspended"),
        ],
        FailingModels = [PrimaryModel],
        FallbackDepth = 1,
    };
}
