using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Tests.Turns;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Core.Models;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Operations;

/// <summary>
/// W10.7A pre-merge remediation — <b>a provider that reports no usage must not produce a measured cost
/// of zero.</b>
///
/// <para>
/// <b>The defect these pin.</b> The provider adapter mapped an absent usage block to <c>0</c> tokens.
/// Price lookup then computed <c>CostOf(0, 0)</c> — a real decimal, not null — and
/// <see cref="AiCostReconciler.BasisFor"/> labelled it <see cref="AiCostBasis.ActualRecorded"/>. So an
/// execution the estate was told nothing about was recorded as a <em>measured</em> cost of nothing, and
/// every budget ceiling passes a zero. The zero was correct at every step downstream; it was fabricated
/// once, at the boundary, and then propagated faithfully.
/// </para>
/// <para>
/// <b>The three states, and which test pins each.</b>
/// </para>
/// <list type="bullet">
/// <item><description><b>A — measured zero:</b> the provider reported <c>0</c>.
/// <see cref="A_reported_zero_IS_a_measurement_and_may_be_priced"/>.</description></item>
/// <item><description><b>B — measured non-zero:</b> the provider reported a count.
/// <see cref="B_reported_usage_is_priced_from_the_measurement"/>.</description></item>
/// <item><description><b>C — usage unavailable:</b> the provider reported nothing.
/// <see cref="C_absent_usage_is_not_a_measurement"/>, and the two tests that follow it.</description></item>
/// </list>
/// <para>
/// <b>Every refusal is paired with a control.</b> A test asserting only "absent usage is not priced"
/// passes just as well against an estate that prices nothing at all — so A and B assert the priced
/// outcomes that the same fixture still produces.
/// </para>
/// </remarks>
public sealed class UsageAvailabilityTests
{
    private const int In = 900;
    private const int Out = 100;

    [Fact]
    public void C_absent_usage_is_not_a_measurement()
    {
        var path = GovernedPath.Compose(W7eFixture.PricedSole(
            tokensIn: In, tokensOut: Out, usageReported: false));

        Run(path);

        var entry = path.Ledger.Entries()[0];

        // The estate was told nothing, and the entry says so rather than saying zero. This is the whole
        // of C: the tokens are absent, not falsified.
        Assert.Null(entry.TokensIn);
        Assert.Null(entry.TokensOut);
        Assert.Null(entry.TotalTokens);
        Assert.False(entry.HasReportedUsage);
    }

    [Fact]
    public void C_absent_usage_cannot_produce_ActualRecorded()
    {
        var path = GovernedPath.Compose(W7eFixture.PricedSole(
            tokensIn: In, tokensOut: Out, usageReported: false));

        Run(path);

        var entry = path.Ledger.Entries()[0];

        // TASK 4's requirement, stated as an assertion. A price EXISTS for this route — the control
        // below prices it — so nothing but the missing measurement stands between this entry and an
        // ActualRecorded basis.
        Assert.NotEqual(AiCostBasis.ActualRecorded, entry.CostBasis);
        Assert.Null(entry.ActualCost);
    }

    [Fact]
    public void C_absent_usage_cannot_produce_a_zero_cost()
    {
        var path = GovernedPath.Compose(W7eFixture.PricedSole(
            tokensIn: In, tokensOut: Out, usageReported: false));

        Run(path);

        var entry = path.Ledger.Entries()[0];

        // NOT ZERO. A zero here is the assertion that the call was free, which is the one thing an
        // unmeasured execution certainly is not.
        Assert.NotEqual(0m, entry.ActualCost);

        // And the entry's authoritative figure is never a fabricated zero. It is either the untaken
        // route's own PREDICTION — correctly labelled Estimated, and present because the route is
        // priced — or nothing at all. What it cannot be is a measured-looking 0.
        Assert.NotEqual(0m, entry.AuthoritativeCost);
        Assert.True(
            entry.AuthoritativeCost is null || entry.CostBasis is AiCostBasis.Estimated,
            "an unmeasured execution may carry a prediction, and only ever labelled as one");
    }

    [Fact]
    public void A_reported_zero_IS_a_measurement_and_may_be_priced()
    {
        // CONTROL for C, and the case that must NOT be swept up by the fix. The provider was asked and
        // answered "zero" — that is a measurement, and pricing it is correct. An over-broad fix that
        // treated every zero as absence would break this, which is why it is asserted.
        var path = GovernedPath.Compose(W7eFixture.PricedSole(
            tokensIn: 0, tokensOut: 0, usageReported: true));

        Run(path);

        var entry = path.Ledger.Entries()[0];

        Assert.Equal(0, entry.TokensIn);
        Assert.True(entry.HasReportedUsage);
        Assert.Equal(AiCostBasis.ActualRecorded, entry.CostBasis);
        Assert.Equal(0m, entry.ActualCost);
    }

    [Fact]
    public void B_reported_usage_is_priced_from_the_measurement()
    {
        // CONTROL for C, at the other end: a reported count is still priced, so the fix removed the
        // fabrication without removing the measurement.
        var path = GovernedPath.Compose(W7eFixture.PricedSole(
            tokensIn: In, tokensOut: Out, usageReported: true));

        Run(path);

        var entry = path.Ledger.Entries()[0];

        Assert.Equal(In, entry.TokensIn);
        Assert.Equal(Out, entry.TokensOut);
        Assert.Equal(AiCostBasis.ActualRecorded, entry.CostBasis);
        Assert.NotNull(entry.ActualCost);
        Assert.True(entry.ActualCost > 0m, "a reported usage against a real rate must price above zero");
    }

    [Fact]
    public void Pricing_available_with_usage_unavailable_still_yields_a_cost_that_cannot_be_recorded()
    {
        // TASK 3's exact requirement: pricing known, usage unknown, ACTUAL cost unknown. The route IS
        // priced — the rate table carries it — and the entry still carries no measured cost, because a
        // theoretical price is not a measurement of what was consumed.
        var path = GovernedPath.Compose(W7eFixture.PricedSole(
            tokensIn: In, tokensOut: Out, usageReported: false));

        Run(path);

        var entry = path.Ledger.Entries()[0];

        Assert.Null(entry.ActualCost);
        Assert.NotEqual(AiCostBasis.ActualRecorded, entry.CostBasis);

        // The prediction, where one existed, is still reported — and is labelled as a prediction rather
        // than promoted to a measurement.
        if (entry.EstimatedCost is not null)
        {
            Assert.Equal(AiCostBasis.Estimated, entry.CostBasis);
        }
    }

    [Fact]
    public void An_unreported_execution_is_counted_as_unreported_rather_than_adding_zero()
    {
        // The aggregate sums the entries that REPORTED and counts the rest. Folding a zero in here
        // would rebuild the same confusion one level up: a token total indistinguishable from a real one.
        var path = GovernedPath.Compose(W7eFixture.PricedSole(
            tokensIn: In, tokensOut: Out, usageReported: false));

        Run(path);

        var report = path.Ledger.Query(AiUsageQuery.All);
        var bucket = Assert.Single(report.Buckets);

        Assert.Equal(1, bucket.Executions);
        Assert.Equal(0, bucket.TokensIn);
        Assert.Equal(0, bucket.TokensOut);
        Assert.Equal(1, bucket.UnreportedUsage);
        Assert.Equal(0, bucket.UnpricedExecutions);
    }

    [Fact]
    public void The_gateway_never_reports_a_number_it_was_not_given()
    {
        // The narrowest statement of the whole remediation, at the layer that caused it: the adapter
        // used to coalesce a null usage block to 0. The outcome now carries null, and the Platform
        // shape beside it cannot be the authority for the cost basis.
        var unmeasured = ModelGatewayOutcome.Unmeasured(new ModelInvocationResult
        {
            Success = true,
        });

        Assert.Null(unmeasured.TokensIn);
        Assert.Null(unmeasured.TokensOut);
        Assert.False(unmeasured.HasReportedUsage);
    }
}