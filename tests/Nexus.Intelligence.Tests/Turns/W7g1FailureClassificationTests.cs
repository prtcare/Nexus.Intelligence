using System;
using System.Linq;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Tests.Operations;
using Nexus.Platform.Contracts.Models;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Turns;

// W7G.1 TASK 1: the gate that typed failure classification crosses the provider seam, and the proof
// that it arrives at the caller unchanged.
//
// WHAT THIS FILE ADDS. W7G closed the leak half of Gate 7 - the provider's own error text no longer
// reaches a consumer - and left the classification half open, because ModelInvocationResult carried
// provider failure as a single free-text field and every provider-reported failure therefore arrived
// downstream as one undifferentiated category. There was no typed channel to branch on, so a deadline,
// a rejected credential, a retired model and an unreachable host were the same fact to every layer
// above the seam.
//
// THE ESTATE BELOW IS ONE ROUTE ON PURPOSE. A classified provider failure is only observable at the
// caller when there is no alternate to absorb it; on a two-route estate the primary's failure fails
// over to a healthy model, the turn succeeds, and the classification is never surfaced. So the proof
// runs on a sole route and reads the failure the caller actually receives.
//
// ALL THREE SURFACES THE CLASSIFICATION REACHES ARE ASSERTED, AND TWO OF THEM ARE INDEPENDENT WRITES.
// This distinction is the reason the test asserts three things rather than one, and it was established
// by mutation rather than assumed:
//
//   - The caller's AiFailure, and the operations view an operator reads, are both derived from the same
//     RouteOutcome the routing pipeline returns. They are two READINGS of one write, so asserting both
//     pins that the classification survives into the operator-visible surface - a separate contract from
//     the caller's - but it does not make the two assertions independent evidence.
//
//   - The reliability attempt is the independent one. It is written from a different fact object, and it
//     is what the reliability plane and the circuit breaker read when they decide whether a route's
//     recent failures were provider faults or model faults. A classification that reached the caller and
//     the audit record but not the reliability history would leave the failover plane judging a route on
//     an undifferentiated failure count, which is exactly the state W7G.1 was opened to end.
public sealed class W7g1FailureClassificationTests
{
    /// <summary>The caller's request identifier, constant across the theory.</summary>
    private const string RequestId = "req-w7g1-classification";

    /// <summary>
    /// Every condition the seam can classify reaches the caller as its corresponding category.
    /// </summary>
    /// <remarks>
    /// <para>
    /// All eleven members are here rather than a representative sample. The mapping is the deliverable,
    /// and a mapping proved for two rows is a mapping that can be wrong in the other nine without any
    /// test saying so - which is the shape of gap this gate was opened to close.
    /// </para>
    /// <para>
    /// The expected category is written out per row rather than derived from the name, so the test
    /// states the correspondence instead of agreeing with whatever the mapping happens to do. The
    /// correspondence itself - that the two enumerations declare the same members at the same values -
    /// is a separate assertion in <c>W7g1ProviderFailureSeamTests</c>, because it is a property of the
    /// declarations rather than of any one execution.
    /// </para>
    /// </remarks>
    [Theory]
    [InlineData(ModelFailureKind.AiUnavailable, AiFailureCategory.AiUnavailable)]
    [InlineData(ModelFailureKind.ProviderUnavailable, AiFailureCategory.ProviderUnavailable)]
    [InlineData(ModelFailureKind.ModelUnavailable, AiFailureCategory.ModelUnavailable)]
    [InlineData(ModelFailureKind.PolicyBlocked, AiFailureCategory.PolicyBlocked)]
    [InlineData(ModelFailureKind.DataExposureBlocked, AiFailureCategory.DataExposureBlocked)]
    [InlineData(ModelFailureKind.ToolPermissionDenied, AiFailureCategory.ToolPermissionDenied)]
    [InlineData(ModelFailureKind.BudgetBlocked, AiFailureCategory.BudgetBlocked)]
    [InlineData(ModelFailureKind.Timeout, AiFailureCategory.Timeout)]
    [InlineData(ModelFailureKind.InvalidOutput, AiFailureCategory.InvalidOutput)]
    [InlineData(ModelFailureKind.CapabilityNotFound, AiFailureCategory.CapabilityNotFound)]
    [InlineData(ModelFailureKind.HumanDecisionRequired, AiFailureCategory.HumanDecisionRequired)]
    public void AClassifiedProviderFailure_ReachesTheCallerAsItsOwnCategory(
        ModelFailureKind classified,
        AiFailureCategory expected)
    {
        var path = GovernedPath.Compose(PricedSole(
            failingModels: [PrimaryModel],
            failingClassification: classified));

        var outcome = Run(path, RequestId);

        Assert.False(Succeeded(outcome));
        Assert.NotNull(outcome.Failure);
        Assert.Equal(expected, outcome.Failure!.Category);

        // The category carries its own semantics with it. Asserting this rather than the category alone
        // is what would catch a mapping that produced the right name by way of the wrong row: a Timeout
        // reported as retryable is a different estate from one reported as a policy block.
        Assert.Equal(expected.IsRetryable(), outcome.Failure.Retryable);

        // The provider's own text does not cross, on this path either. The seam's failure message is
        // distinctive; the caller's must not contain it. This is the W7G leak assertion re-stated for
        // the classified path, because the classification is a new field on the same response and a
        // change that widened the leak would not have to touch the message to do it.
        Assert.DoesNotContain("recording seam", outcome.Failure.Message, StringComparison.OrdinalIgnoreCase);

        var executionId = Assert.Single(path.Ledger.Entries().Select(entry => entry.ExecutionId).Distinct());
        Assert.Equal(expected, path.Operations.Execution(executionId)!.FailureCategory);

        // The independent write. See the file header: this is the one surface fed by a different fact
        // object from the two above, so it is the assertion that would catch the classification being
        // wired into the caller's path and the audit record but not into the reliability plane - where a
        // provider fault and a model fault have to stay distinguishable for failover to judge a route.
        var attempt = Assert.Single(path.Reliability.AttemptsFor(PrimaryProvider, PrimaryModel));
        Assert.Equal(expected, attempt.FailureCategory);
        Assert.False(attempt.Succeeded);
    }

    /// <summary>
    /// A failure with no classification behaves exactly as every provider failure did before the
    /// member existed.
    /// </summary>
    /// <remarks>
    /// This is the control that makes the theory above a statement about the classification rather than
    /// about the estate. It is the same sole-route estate failing in the same way, with the
    /// classification omitted - so the seam is the pre-W7G.1 producer that assigns free text and
    /// nothing else. The answer must be <see cref="AiFailureCategory.ProviderUnavailable"/>, because
    /// that is what every provider-reported failure was before, and an adapter that has not been
    /// updated must keep working.
    /// </remarks>
    [Fact]
    public void AnUnclassifiedProviderFailure_ArrivesAsProviderUnavailable_AndStaysFailoverEligible()
    {
        var path = GovernedPath.Compose(PricedSole(failingModels: [PrimaryModel]));

        var outcome = Run(path, RequestId);

        Assert.False(Succeeded(outcome));
        Assert.Equal(AiFailureCategory.ProviderUnavailable, outcome.Failure!.Category);

        // Retryable and an unavailability, which is what makes the failover plane willing to consider
        // an alternate. A missing classification that landed on a non-retryable category instead would
        // turn a recoverable provider outage into a terminal refusal for every adapter not yet updated
        // - and it would do it silently, because the category would still look plausible.
        Assert.True(outcome.Failure.Retryable);
        Assert.True(outcome.Failure.Category.IsUnavailability());

        // The reliability plane sees the same fact, so an adapter that has not been updated is not
        // merely tolerated by the caller - it keeps the failover plane judging its route exactly as it
        // did before the member existed.
        var attempt = Assert.Single(path.Reliability.AttemptsFor(PrimaryProvider, PrimaryModel));
        Assert.Equal(AiFailureCategory.ProviderUnavailable, attempt.FailureCategory);
    }

    /// <summary>
    /// A successful result carries no classification, at the caller and on the record.
    /// </summary>
    /// <remarks>
    /// The directive's fifth item, and it is about absence rather than presence: a result that reported
    /// success while naming a failure is a contradiction every consumer would resolve differently. Both
    /// places a consumer can look are asserted, because the invariant has to hold wherever it is read.
    /// </remarks>
    [Fact]
    public void ASuccessfulResult_CarriesNoFailureClassification()
    {
        var path = GovernedPath.Compose(PricedSole());

        var outcome = Run(path, RequestId);

        Assert.True(Succeeded(outcome));
        Assert.Null(outcome.Failure);

        var executionId = Assert.Single(path.Ledger.Entries().Select(entry => entry.ExecutionId).Distinct());
        Assert.Null(path.Operations.Execution(executionId)!.FailureCategory);

        // The success invariant holds on the independent write too. A route that answered is a route
        // that did not fail, and a reliability plane told otherwise would lower a healthy model's success
        // rate while every caller-facing surface still reported success - a defect visible only in the
        // evidence, and only after enough turns to move the rate.
        var attempt = Assert.Single(path.Reliability.AttemptsFor(PrimaryProvider, PrimaryModel));
        Assert.Null(attempt.FailureCategory);
        Assert.True(attempt.Succeeded);
    }

    /// <summary>
    /// A governance refusal keeps the category governance gave it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The directive's fourth item, and it guards the direction the first three do not: the seam's
    /// classification must <em>add</em> precision for provider failures without becoming a second
    /// opinion about refusals this estate made itself. A prohibited capability is refused by the
    /// governance evaluator before any provider is reached, and the category on the caller's failure is
    /// the evaluator's, not anything the seam or the mapping produced.
    /// </para>
    /// <para>
    /// The retryable assertion is the substance. <see cref="AiFailureCategory.PolicyBlocked"/> is one of
    /// the four deterministic refusals - retrying asks the same question again in the hope of a
    /// different answer - so a mapping that overwrote it with a retryable provider category would turn a
    /// standing prohibition into something a retry loop would keep asking for. That is the failure mode
    /// this test exists to make impossible to introduce quietly.
    /// </para>
    /// </remarks>
    [Fact]
    public void AGovernanceRefusal_KeepsItsOwnCategory_RatherThanTheSeams()
    {
        var path = GovernedPath.Compose(PricedSole() with
        {
            Capability = AiCapabilities.CodeReview,
            Dependencies = [GovernedPath.Prohibited(AiCapabilities.CodeReview)],
        });

        var outcome = Run(path, RequestId);

        Assert.False(Succeeded(outcome));
        Assert.Equal(AiFailureCategory.PolicyBlocked, outcome.Failure!.Category);
        Assert.False(outcome.Failure.Retryable);

        // And nothing was asked of a provider, which is what makes this a refusal rather than a failed
        // attempt that happened to be labelled as one.
        Assert.Equal(0, path.Model.Count);
    }
}
