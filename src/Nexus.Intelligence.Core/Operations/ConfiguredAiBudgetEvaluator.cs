using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// The operational budget gate: scoped ceilings, measured against committed spend where configured.
/// </summary>
/// <remarks>
/// <para>
/// <b>The governance budget table is not replaced and is not duplicated.</b> The W7B engine evaluates
/// the policy's ceiling before health and before routing and refuses with
/// <see cref="AiGovernanceRules.BudgetUncovered"/> when nothing covers a priced execution. This gate
/// runs after it, inside routing, and adds the thing the governance engine cannot do: bound spend
/// across executions, against a ledger the governance engine does not hold and must not, because a
/// governance decision that depended on how much had already been spent would stop being reproducible
/// from its own inputs.
/// </para>
/// <para>
/// <b>It can only ever refuse.</b> Nothing here selects or prefers a cheaper route. Cost preference
/// is a ranking weight an operator sets; a gate that also ranked would make "why was this route
/// refused" depend on what it was being compared against.
/// </para>
/// <para>
/// <b>An uncovered priced execution follows the configured behaviour and nothing else.</b> The shipped
/// behaviour is to refuse. An estate that means "we do not run this plane" says so by configuring
/// <see cref="AiBudgetUncoveredBehaviour.Allow"/>, which is a line in a file with a reviewer, rather
/// than by leaving a list empty and getting a widening nobody chose.
/// </para>
/// </remarks>
public sealed class ConfiguredAiBudgetEvaluator : IAiBudgetEvaluator
{
    private readonly AiOperationsBudgetPolicy _policy;
    private readonly IAiCostLedger? _ledger;

    /// <summary>Builds the gate over a policy, with a ledger for period ceilings where one exists.</summary>
    /// <remarks>
    /// The ledger is optional because a per-execution ceiling needs no history and an estate may
    /// legitimately configure only those. A period ceiling with no ledger is <b>refused rather than
    /// degraded</b> — see <see cref="Evaluate"/> — because treating a monthly ceiling as a per-call
    /// one would silently substitute a different control for the one an operator wrote.
    /// </remarks>
    public ConfiguredAiBudgetEvaluator(AiOperationsBudgetPolicy policy, IAiCostLedger? ledger = null)
    {
        ArgumentNullException.ThrowIfNull(policy);

        policy.Validate();

        _policy = policy;
        _ledger = ledger;
    }

    /// <inheritdoc />
    public AiBudgetDecision Evaluate(AiBudgetContext context)
    {
        ArgumentNullException.ThrowIfNull(context);

        if (!_policy.Available)
        {
            return AiBudgetDecision.Allow(
                null, AiBudgetScope.Unscoped, AiBudgetPeriod.None, AiBudgetOutcome.NotConfigured);
        }

        // An unpriced execution has no figure to compare against any ceiling. That is not "unlimited":
        // it is "this gate has nothing to say", and the governance plane's own cost stage already
        // refuses a priced execution it cannot price. Reporting a refusal here as well would produce
        // two rules for one fact and two different reasons for the same outcome.
        //
        // W7F TASK 5: what it must NOT do is report the permission as coverage. The outcome below says
        // which of the two facts this is — an allowance nobody measured, or a refusal because this
        // estate requires a route it runs to be priceable — and the verdict alone never did.
        if (context.ProjectedCost is not { } projected)
        {
            return _policy.OnUnpricedExecution is AiBudgetUncoveredBehaviour.Refuse
                ? Refuse(
                    ruleId: null,
                    scope: AiBudgetScope.Unscoped,
                    period: AiBudgetPeriod.None,
                    context,
                    AiBudgetOutcome.RefusedUnpriced,
                    $"No price is available for capability '{context.Capability}' on model "
                    + $"'{context.ModelId ?? "(unnamed)"}', so no ceiling can be measured against this "
                    + "execution. The configured behaviour for an unpriceable route is to refuse it, "
                    + "because a route whose cost nobody can state is not a route whose cost is zero.")
                : AiBudgetDecision.Allow(
                    null, AiBudgetScope.Unscoped, AiBudgetPeriod.None, AiBudgetOutcome.Unpriced);
        }

        var rule = _policy.RuleFor(context);

        if (rule is null)
        {
            return _policy.OnUncoveredPricedExecution is AiBudgetUncoveredBehaviour.Refuse
                ? Refuse(
                    ruleId: null,
                    scope: AiBudgetScope.Unscoped,
                    period: AiBudgetPeriod.None,
                    context,
                    AiBudgetOutcome.RefusedUncovered,
                    $"The execution is projected at {projected} and no operational budget rule covers "
                    + $"capability '{context.Capability}'. The configured behaviour for an uncovered priced "
                    + "execution is to refuse it.")
                : AiBudgetDecision.Allow(
                    null, AiBudgetScope.Unscoped, AiBudgetPeriod.None, AiBudgetOutcome.AllowedUncovered)
                    with { ProjectedCost = projected, Currency = context.Currency };
        }

        // A ceiling is a number with a unit. Comparing across units is not a near miss, it is a
        // comparison that cannot be made, and making it silently is the defect the currency field
        // exists to prevent — the same reading the governance engine already applies to its own table.
        if (!string.Equals(context.Currency, rule.Currency, StringComparison.Ordinal))
        {
            return Refuse(
                rule.RuleId,
                rule.Scope,
                rule.Period,
                context,
                AiBudgetOutcome.CurrencyMismatch,
                context.Currency is { } currency
                    ? $"Budget rule '{rule.RuleId}' is denominated in '{rule.Currency}' and the execution is "
                      + $"denominated in '{currency}'. A ceiling cannot be enforced across currencies."
                    : $"Budget rule '{rule.RuleId}' is denominated in '{rule.Currency}' and the execution names "
                      + "no currency, so its cost cannot be compared against the ceiling at all.");
        }

        return rule.Period is AiBudgetPeriod.None
            ? EvaluatePerExecution(rule, context, projected)
            : EvaluateOverPeriod(rule, context, projected);
    }

    /// <summary>A ceiling that bounds this execution alone.</summary>
    private AiBudgetDecision EvaluatePerExecution(
        AiOperationsBudgetRule rule, AiBudgetContext context, decimal projected)
    {
        if (projected <= rule.Ceiling)
        {
            return Within(rule, context, projected);
        }

        return Exceeded(
            rule,
            context,
            $"The execution is projected at {projected} {rule.Currency} and budget rule '{rule.RuleId}' has a "
            + $"ceiling of {rule.Ceiling} {rule.Currency}. {rule.Rationale}",
            committedSpend: null);
    }

    /// <summary>
    /// A ceiling that bounds cumulative spend over a window.
    /// </summary>
    /// <remarks>
    /// <b>The comparison is against committed spend plus the projection, not against either alone.</b>
    /// Comparing the projection alone would let a request that fits inside the ceiling pass on the
    /// thousandth time it was made; comparing committed spend alone would refuse an execution that had
    /// not run yet on the strength of spend it had not incurred. The sum is the only figure that
    /// answers "will this put us over".
    /// </remarks>
    private AiBudgetDecision EvaluateOverPeriod(
        AiOperationsBudgetRule rule, AiBudgetContext context, decimal projected)
    {
        if (_ledger is null)
        {
            return Refuse(
                rule.RuleId,
                rule.Scope,
                rule.Period,
                context,
                AiBudgetOutcome.WindowUnmeasurable,
                $"Budget rule '{rule.RuleId}' bounds spend over a '{rule.Period}' window and no cost ledger "
                + "is available to measure that window. Refusing rather than falling back to a per-execution "
                + "check, because the two are different controls and silently substituting one for the other "
                + "would enforce a ceiling nobody wrote.");
        }

        var (from, to) = WindowFor(rule.Period, context.Now);
        var query = SpendQueryFor(rule, context, from, to);
        var committed = _ledger.CommittedSpend(query, rule.Currency);

        var total = committed.Amount + projected;

        if (total <= rule.Ceiling)
        {
            return Within(rule, context, projected);
        }

        var coverage = committed.UnpricedEntries > 0
            ? $" {committed.UnpricedEntries} execution(s) in the window had no price and contribute nothing "
              + "to the committed figure."
            : string.Empty;

        return Exceeded(
            rule,
            context,
            $"The execution is projected at {projected} {rule.Currency} and {committed.Amount} {rule.Currency} "
            + $"is already committed this {rule.Period.ToString().ToLowerInvariant()}, totalling {total} against "
            + $"budget rule '{rule.RuleId}' with a ceiling of {rule.Ceiling} {rule.Currency}.{coverage} "
            + rule.Rationale,
            committed.Amount);
    }

    /// <summary>The half-open window a period covers, in UTC.</summary>
    /// <remarks>
    /// Half-open — <c>[from, to)</c> — so that an execution recorded exactly at midnight belongs to one
    /// day and not to two. An inclusive upper bound would let a daily ceiling count the same execution
    /// twice at the boundary.
    /// </remarks>
    private static (DateTimeOffset From, DateTimeOffset To) WindowFor(AiBudgetPeriod period, DateTimeOffset now)
    {
        var utc = now.ToUniversalTime();

        return period switch
        {
            AiBudgetPeriod.Daily => (
                new DateTimeOffset(utc.Year, utc.Month, utc.Day, 0, 0, 0, TimeSpan.Zero),
                new DateTimeOffset(utc.Year, utc.Month, utc.Day, 0, 0, 0, TimeSpan.Zero).AddDays(1)),

            AiBudgetPeriod.Monthly => (
                new DateTimeOffset(utc.Year, utc.Month, 1, 0, 0, 0, TimeSpan.Zero),
                new DateTimeOffset(utc.Year, utc.Month, 1, 0, 0, 0, TimeSpan.Zero).AddMonths(1)),

            _ => (DateTimeOffset.MinValue, DateTimeOffset.MaxValue),
        };
    }

    /// <summary>
    /// The spend query a window aggregates over.
    /// </summary>
    /// <remarks>
    /// Scoped by exactly the fields the rule sets, and by the context's values for them — which is
    /// sound because the rule only reached this method after <see cref="AiOperationsBudgetRule.Applies"/>
    /// matched it. Scoping by every field would make a tenant-scoped rule aggregate over one workspace
    /// and silently under-count.
    /// </remarks>
    private static AiCostQuery SpendQueryFor(
        AiOperationsBudgetRule rule, AiBudgetContext context, DateTimeOffset from, DateTimeOffset to) => new()
        {
            Capability = rule.Capability is null ? null : context.Capability,
            ProductId = rule.ProductId is null ? null : context.ProductId,
            TenantId = rule.TenantId is null ? null : context.TenantId,
            WorkspaceId = rule.WorkspaceId is null ? null : context.WorkspaceId,
            ProviderId = rule.ProviderId is null ? null : context.ProviderId,
            ModelId = rule.ModelId is null ? null : context.ModelId,
            From = from,
            To = to,
        };

    /// <summary>A ceiling that was compared and satisfied.</summary>
    /// <remarks>
    /// <para>
    /// <b>W7F TASK 4: the projection is carried on the allow as well as on the refusal.</b> The member's
    /// own summary has always said it is the figure the verdict was decided against, and until now only
    /// the refusals carried it — so a <see cref="AiBudgetOutcome.WithinCeiling"/> outcome told a reader
    /// that a ceiling had been satisfied and left the reader to find out by how much. The estate holds
    /// the figure at this point; a surface that withheld it made the estate's own measurement
    /// unobservable and invited a consumer to reconstruct it from the cost ledger, which is inference of
    /// exactly the kind TASK 4 removes.
    /// </para>
    /// <para>
    /// It is not populated where no comparison happened, which is a different statement: a gate that was
    /// never composed carries no projection because it reached no figure, and an unpriceable route
    /// carries none because there was none to reach. Null therefore reads as "no amount was measured"
    /// rather than "an amount was measured and is being withheld".
    /// </para>
    /// </remarks>
    private static AiBudgetDecision Within(
        AiOperationsBudgetRule rule, AiBudgetContext context, decimal projected)
        => AiBudgetDecision.Allow(
            rule.RuleId, rule.Scope, rule.Period, AiBudgetOutcome.WithinCeiling)
            with
        {
            ProjectedCost = projected,
            Currency = rule.Currency ?? context.Currency,
        };

    private AiBudgetDecision Exceeded(
        AiOperationsBudgetRule rule, AiBudgetContext context, string reason, decimal? committedSpend) => new()
        {
            Verdict = rule.OnExceeded,
            Outcome = AiBudgetOutcome.RefusedOverCeiling,
            RuleId = rule.RuleId,
            Scope = rule.Scope,
            Period = rule.Period,
            Reason = reason,
            ProjectedCost = context.ProjectedCost,
            CommittedSpend = committedSpend,
            Currency = rule.Currency,
            FailureCategory = AiFailureCategory.BudgetBlocked,
        };

    private static AiBudgetDecision Refuse(
        string? ruleId,
        AiBudgetScope scope,
        AiBudgetPeriod period,
        AiBudgetContext context,
        AiBudgetOutcome outcome,
        string reason) => new()
        {
            Verdict = AiGovernanceVerdict.Block,
            Outcome = outcome,
            RuleId = ruleId,
            Scope = scope,
            Period = period,
            Reason = reason,
            ProjectedCost = context.ProjectedCost,
            Currency = context.Currency,
            FailureCategory = AiFailureCategory.BudgetBlocked,
        };
}
