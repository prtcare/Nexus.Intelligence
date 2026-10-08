namespace Nexus.Intelligence.Contracts;

/// <summary>
/// A scoped operational cost ceiling: what may be spent, on what, over what window.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is not a second copy of <see cref="AiGovernanceBudgetRule"/>, and the difference is the
/// point.</b> The governance rule answers a governance question — "is this execution permitted
/// against the policy's ceiling" — and it is evaluated by the deterministic governance engine inside
/// the policy gate, before health and before routing. This rule answers an operational question —
/// "what is this estate permitted to spend" — and it is evaluated against committed spend, which
/// the governance engine cannot see and must not see, because a governance decision that depended
/// on how much had already been spent would stop being reproducible from its inputs.
/// </para>
/// <para>
/// <b>The scope fields are nullable and conjunctive.</b> Every field that is set must match, so
/// adding a field narrows a rule rather than widening it. A rule with no scope field set bounds
/// everything it matches, which is the catch-all and is spelled that way rather than being spelled
/// by an empty string.
/// </para>
/// <para>
/// <b>No limits are invented here.</b> The structure is empty by default and an estate that
/// configures no rules gets the behaviour its policy explicitly names in
/// <see cref="AiOperationsBudgetPolicy.OnUncoveredPricedExecution"/>.
/// </para>
/// </remarks>
public sealed record AiOperationsBudgetRule
{
    /// <summary>The rule's stable identifier. Appears on every verdict it produces.</summary>
    public required string RuleId { get; init; }

    /// <summary>Restrict to a capability.</summary>
    public CapabilityId? Capability { get; init; }

    /// <summary>Restrict to a product.</summary>
    public string? ProductId { get; init; }

    /// <summary>Restrict to a tenant.</summary>
    public string? TenantId { get; init; }

    /// <summary>Restrict to a workspace.</summary>
    public string? WorkspaceId { get; init; }

    /// <summary>Restrict to a provider.</summary>
    public string? ProviderId { get; init; }

    /// <summary>Restrict to a model.</summary>
    public string? ModelId { get; init; }

    /// <summary>The ceiling, in <see cref="Currency"/>.</summary>
    public required decimal Ceiling { get; init; }

    /// <summary>ISO 4217 currency of <see cref="Ceiling"/>.</summary>
    public required string Currency { get; init; }

    /// <summary>
    /// The window the ceiling is measured over.
    /// </summary>
    /// <remarks>
    /// <see cref="AiBudgetPeriod.None"/> bounds a single execution: the ceiling is compared against
    /// the projected cost of the one execution being evaluated. Any other member bounds cumulative
    /// spend over that window, which requires the cost ledger and is therefore evaluated only where
    /// a ledger is available — a period budget with no ledger refuses rather than silently degrading
    /// to a per-execution check, because the two are different controls with different meanings.
    /// </remarks>
    public AiBudgetPeriod Period { get; init; } = AiBudgetPeriod.None;

    /// <summary>What to return when the ceiling is exceeded. May not be <see cref="AiGovernanceVerdict.Allow"/>.</summary>
    public AiGovernanceVerdict OnExceeded { get; init; } = AiGovernanceVerdict.Block;

    /// <summary>Why the ceiling is where it is. Required, so the table is reviewable.</summary>
    public required string Rationale { get; init; }

    /// <summary>Which dimension this rule narrows on, derived from the fields it actually sets.</summary>
    /// <remarks>
    /// Derived rather than declared, so a rule cannot claim to be narrower than it is. Where a rule
    /// sets several fields, the first set in the fixed order below names the scope and the rest are
    /// reported as additional constraints — the label is a summary, and the fields are the truth.
    /// </remarks>
    public AiBudgetScope Scope => this switch
    {
        { Capability: not null } => AiBudgetScope.Capability,
        { ProductId: not null } => AiBudgetScope.Product,
        { TenantId: not null } => AiBudgetScope.Tenant,
        { WorkspaceId: not null } => AiBudgetScope.Workspace,
        { ProviderId: not null } => AiBudgetScope.Provider,
        { ModelId: not null } => AiBudgetScope.Model,
        _ => AiBudgetScope.Unscoped,
    };

    /// <summary>True when every scope field this rule sets matches the context.</summary>
    public bool Applies(AiBudgetContext context)
    {
        ArgumentNullException.ThrowIfNull(context);

        return (Capability is null || Capability == context.Capability)
            && Matches(ProductId, context.ProductId)
            && Matches(TenantId, context.TenantId)
            && Matches(WorkspaceId, context.WorkspaceId)
            && Matches(ProviderId, context.ProviderId)
            && Matches(ModelId, context.ModelId);
    }

    /// <summary>How many scope fields this rule sets. Higher is more specific.</summary>
    public int Specificity =>
        (Capability is null ? 0 : 1)
        + (ProductId is null ? 0 : 1)
        + (TenantId is null ? 0 : 1)
        + (WorkspaceId is null ? 0 : 1)
        + (ProviderId is null ? 0 : 1)
        + (ModelId is null ? 0 : 1);

    private static bool Matches(string? declared, string? actual)
        => declared is null || string.Equals(declared, actual, StringComparison.Ordinal);
}

/// <summary>Everything a budget verdict is decided from.</summary>
public sealed record AiBudgetContext
{
    /// <summary>The capability about to run.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>The product the spend would be attributed to.</summary>
    public string? ProductId { get; init; }

    /// <summary>The tenant the spend would be attributed to.</summary>
    public string? TenantId { get; init; }

    /// <summary>The workspace the spend would be attributed to.</summary>
    public string? WorkspaceId { get; init; }

    /// <summary>The provider the route would use.</summary>
    public string? ProviderId { get; init; }

    /// <summary>The model the route would use.</summary>
    public string? ModelId { get; init; }

    /// <summary>The cost the execution is projected to incur, or null when it cannot be priced.</summary>
    public decimal? ProjectedCost { get; init; }

    /// <summary>The currency <see cref="ProjectedCost"/> is in.</summary>
    public string? Currency { get; init; }

    /// <summary>When the evaluation is happening, for window selection.</summary>
    public required DateTimeOffset Now { get; init; }
}

/// <summary>What the operational budget plane concluded about one proposed execution.</summary>
public sealed record AiBudgetDecision
{
    /// <summary>The verdict. <see cref="AiGovernanceVerdict.Allow"/> means the spend is within budget.</summary>
    public required AiGovernanceVerdict Verdict { get; init; }

    /// <summary>
    /// Which conclusion this is, as a member. The vocabulary the verdict alone could not express.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>W7F TASK 4, and the member that resolves the ambiguity.</b> Before it, three different facts
    /// arrived as the same decision: a gate that was never composed, a route the gate could not price,
    /// and a route no rule covered but the estate had chosen to permit. All three were
    /// <c>{ Verdict = Allow, RuleId = null }</c>. Reading them apart meant reading
    /// <see cref="ProjectedCost"/> and the policy, and a consumer without the policy could not do it
    /// at all.
    /// </para>
    /// <para>
    /// <b>It is never inferred from the verdict.</b> A refusal is not always <see cref="RuleId"/>-bearing
    /// and an allow is not always coverage: <see cref="AiBudgetOutcome.RefusedUncovered"/> has no rule
    /// to name and <see cref="AiBudgetOutcome.Unpriced"/> has no amount to compare. This member is set
    /// by the gate at the point it concludes, where both facts are known, and nowhere else.
    /// </para>
    /// <para>
    /// <see cref="AiBudgetOutcome.NotEvaluated"/> is the default, so a decision constructed without
    /// stating an outcome reports that it states nothing rather than claiming an allow it did not make.
    /// </para>
    /// </remarks>
    public AiBudgetOutcome Outcome { get; init; } = AiBudgetOutcome.NotEvaluated;

    /// <summary>The rule that produced the verdict, where one applied.</summary>
    /// <remarks>
    /// Null has two distinct meanings and <see cref="Outcome"/> is what tells them apart: a refusal
    /// with no rule is <see cref="AiBudgetOutcome.RefusedUncovered"/>, and a permission with no rule is
    /// one of <see cref="AiBudgetOutcome.AllowedUncovered"/>,
    /// <see cref="AiBudgetOutcome.Unpriced"/> or <see cref="AiBudgetOutcome.NotConfigured"/>. A reader
    /// that treated a null identifier as "no ceiling applied, therefore nothing was spent" would be
    /// reading a null as a measurement.
    /// </remarks>
    public string? RuleId { get; init; }

    /// <summary>The scope of the rule that applied, where one did.</summary>
    public AiBudgetScope Scope { get; init; } = AiBudgetScope.Unscoped;

    /// <summary>The window the rule measured over, where one applied.</summary>
    public AiBudgetPeriod Period { get; init; } = AiBudgetPeriod.None;

    /// <summary>A caller-safe explanation. Always populated when the verdict is not allow.</summary>
    public string? Reason { get; init; }

    /// <summary>The projected cost the verdict was decided against.</summary>
    /// <remarks>
    /// <para>
    /// <b>W7F TASK 4: populated wherever a projection existed, on a permission as well as on a refusal.</b>
    /// A <see cref="AiBudgetOutcome.WithinCeiling"/> outcome states that a ceiling was compared and
    /// satisfied, and this is the figure it was satisfied against — so a reader can see the margin rather
    /// than only the conclusion. Withholding it on the permissive outcomes would have left the estate's own
    /// measurement on no surface and made reconstructing it a matter of inference.
    /// </para>
    /// <para>
    /// Null means no amount was ever reached, which is not the same as an amount being withheld:
    /// <see cref="AiBudgetOutcome.NotConfigured"/> is a gate that does not exist and
    /// <see cref="AiBudgetOutcome.Unpriced"/> is a route with no figure to compare. Read
    /// <see cref="Outcome"/> for which of those it is.
    /// </para>
    /// </remarks>
    public decimal? ProjectedCost { get; init; }

    /// <summary>Spend already committed in the window, where the rule measured over one.</summary>
    public decimal? CommittedSpend { get; init; }

    /// <summary>The currency the figures are in.</summary>
    public string? Currency { get; init; }

    /// <summary>The failure category this verdict maps to when it is not an allow.</summary>
    public AiFailureCategory FailureCategory { get; init; } = AiFailureCategory.BudgetBlocked;

    /// <summary>True when the spend is within budget.</summary>
    public bool IsAllowed => Verdict is AiGovernanceVerdict.Allow;

    /// <summary>True when the rule refuses outright.</summary>
    public bool IsBlocked => Verdict is AiGovernanceVerdict.Block;

    /// <summary>True when the rule escalates rather than refuses.</summary>
    public bool RequiresHumanDecision => Verdict is AiGovernanceVerdict.HumanDecisionRequired;

    /// <summary>
    /// An allow, with the rule that permitted it where there was one.
    /// </summary>
    /// <remarks>
    /// <b>The outcome is a parameter and not a defaulted one.</b> Three quite different permissions
    /// reach this factory — a rule that was satisfied, a route with no price, and an uncovered route
    /// the estate chose to permit — and a default would make the cheapest of them to write the one
    /// that a new call site gets. Requiring the caller to name it is what stops a gate from acquiring
    /// an allow whose reason nobody stated, which is the defect W7F TASK 4 records.
    /// </remarks>
    public static AiBudgetDecision Allow(
        string? ruleId,
        AiBudgetScope scope,
        AiBudgetPeriod period,
        AiBudgetOutcome outcome) => new()
    {
        Verdict = AiGovernanceVerdict.Allow,
        Outcome = outcome,
        RuleId = ruleId,
        Scope = scope,
        Period = period,
    };
}

/// <summary>
/// A route the estate could price replaced, by failover, by one it cannot.
/// </summary>
/// <remarks>
/// <para>
/// <b>W7F TASK 5.</b> A priced primary that fails over to an unpriced alternate is the moment budget
/// coverage is quietly lost: every ceiling the estate wrote was evaluated against a route that did not
/// serve, and the route that did serve has no figure to compare. Recorded rather than left to be
/// reconstructed, because the two facts that make it up — what the primary would have cost and what
/// the alternate cannot be costed at — live in two different records and neither of them names the
/// other.
/// </para>
/// <para>
/// <b>Only the priced-to-unpriced direction is recorded.</b> The reverse — an unpriced route replaced
/// by a priced one — is a fallback that strictly improved the estate's knowledge, and it is visible
/// from the serving route's own cost basis. Recording it here as well would put a second, weaker
/// statement of the same fact on the operations surface, and the surface would then have two places
/// to disagree.
/// </para>
/// <para>
/// <b>It is a finding, not a refusal.</b> The substitution is reported because a reader must not read
/// the execution's absent cost as a cost of nothing; whether the estate permits an unpriceable route
/// at all is a policy question, answered by <see cref="AiOperationsBudgetPolicy.OnUnpricedExecution"/>
/// and by the governance plane's own cost gate, both before any of this is reached.
/// </para>
/// </remarks>
public sealed record AiBudgetSubstitution
{
    /// <summary>The model of the priced route that did not serve.</summary>
    public required string FromModelId { get; init; }

    /// <summary>The provider of the priced route that did not serve.</summary>
    public required string FromProviderId { get; init; }

    /// <summary>What the route that did not serve was projected to cost.</summary>
    public required decimal FromProjectedCost { get; init; }

    /// <summary>The currency that projection was in.</summary>
    public required string FromCurrency { get; init; }

    /// <summary>The model of the unpriced route that served instead.</summary>
    public required string ToModelId { get; init; }

    /// <summary>The provider of the unpriced route that served instead.</summary>
    public required string ToProviderId { get; init; }

    /// <summary>A caller-safe explanation for the operations surface.</summary>
    public required string Detail { get; init; }

    /// <summary>
    /// The substitution a failover made, or null when it made none.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Derived from the failover record rather than recorded beside it.</b> The primary's
    /// projection and the serving route's absence of one are both already written, so a third write
    /// would be a third record that must agree with the other two and no mechanism that makes it.
    /// This reads them and states the conclusion once.
    /// </para>
    /// <para>
    /// <b>It compares the primary with the route that served, not every route in between.</b> The
    /// directive's case is the primary, and a walk over the whole attempt list would need each
    /// attempt's own projection — which the failover record does not carry, because an attempt that
    /// was invoked is recorded by what it consumed rather than by what it was predicted to consume.
    /// </para>
    /// </remarks>
    public static AiBudgetSubstitution? Between(AiRoutingCandidate? primary, AiRoutingCandidate? selected)
    {
        if (primary?.EstimatedCost is not { } projected
            || primary.CostCurrency is not { Length: > 0 } currency
            || selected is null
            || selected.EstimatedCost is not null)
        {
            return null;
        }

        return new AiBudgetSubstitution
        {
            FromModelId = primary.ModelId,
            FromProviderId = primary.ProviderId,
            FromProjectedCost = projected,
            FromCurrency = currency,
            ToModelId = selected.ModelId,
            ToProviderId = selected.ProviderId,
            Detail = $"The route that served this execution was not the route that was priced. "
                + $"'{primary.ModelId}' on provider '{primary.ProviderId}' was projected at "
                + $"{projected} {currency} and did not serve; '{selected.ModelId}' on provider "
                + $"'{selected.ProviderId}' served instead and has no price, so no ceiling this estate "
                + "wrote was measured against the work that ran. The execution's cost is absent rather "
                + "than zero for that reason.",
        };
    }
}

/// <summary>
/// The operational budget policy: the rules, and what an uncovered priced execution means.
/// </summary>
/// <remarks>
/// <para>
/// <b><see cref="OnUncoveredPricedExecution"/> has no silent default.</b> It is a named member whose
/// shipped value is <see cref="AiBudgetUncoveredBehaviour.Refuse"/>. An estate that means "we do not
/// run an operational budget plane" says so by setting <see cref="AiBudgetUncoveredBehaviour.Allow"/>,
/// which is a configuration act with a file and a reviewer, not an omission.
/// </para>
/// <para>
/// <see cref="Available"/> false is a third state and is not the same as "no rules": it means the
/// evaluation is not performed at all, because the estate has not composed this plane. It exists so
/// that a harness or an estate can be explicit about that rather than reaching it by leaving a
/// collection empty.
/// </para>
/// <para>
/// <b><see cref="OnUnpricedExecution"/> is W7F TASK 5's switch and it shipped permissive.</b> An
/// unpriceable route is not an under-covered one: this gate can only refuse, and refusing every route
/// the estate has not published rates for would make the register's pricing metadata a prerequisite
/// for running anything — while the plane that already asks "may this estate run work it cannot cost"
/// is the governance cost gate, whose answer is
/// <see cref="AiGovernancePolicy.RequireBudgetRuleForPricedExecution"/>. What this gate owes a reader
/// in either posture is the truth about what it knew, which is
/// <see cref="AiBudgetOutcome.Unpriced"/> or <see cref="AiBudgetOutcome.RefusedUnpriced"/> — never a
/// permissive allow that reads as coverage.
/// </para>
/// </remarks>
public sealed record AiOperationsBudgetPolicy
{
    /// <summary>The ceiling rules.</summary>
    public IReadOnlyList<AiOperationsBudgetRule> Rules { get; init; } = [];

    /// <summary>Whether the operational budget plane is evaluated at all.</summary>
    public bool Available { get; init; } = true;

    /// <summary>What an uncovered priced execution means. The shipped default refuses.</summary>
    public AiBudgetUncoveredBehaviour OnUncoveredPricedExecution { get; init; } = AiBudgetUncoveredBehaviour.Refuse;

    /// <summary>
    /// What a route the estate cannot price means. The shipped default permits it, explicitly.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Permissive by default, and the default is argued rather than inherited.</b> The two
    /// uncovered cases are not symmetrical. An estate can price a route and still have written no rule
    /// for it, which is an omission in a table it controls — so the shipped posture refuses. An estate
    /// cannot price a route at all without editing the model register's rates, which is a different
    /// act with a different owner, and refusing here would make this gate the estate's pricing
    /// prerequisite.
    /// </para>
    /// <para>
    /// <b>Refuse is the default, and it is a line in a file with a reviewer that changes it.</b> An
    /// estate that means "nothing runs unless we know what it costs" is the shipped posture; an estate
    /// that means "run it anyway, and record that we did not know the cost" sets
    /// <see cref="AiBudgetUncoveredBehaviour.Allow"/> and every unpriceable route proceeds with
    /// <see cref="AiBudgetOutcome.Unpriced"/> on its record.
    /// </para>
    /// <para>
    /// <b><see cref="AiBudgetUncoveredBehaviour.Allow"/> here means "allow WITH AN UNKNOWN COST", and
    /// never "the cost is zero".</b> The permission and the measurement are separate facts and stay
    /// separate: the execution runs, its usage is recorded as the provider reported it, and its cost
    /// remains unavailable. A reader that treated the permission as an amount would be reading a
    /// decision as a measurement — the defect this member's default now prevents.
    /// </para>
    /// <para>
    /// <b>Changed in W10.7A.</b> This shipped permissive, and no configuration key could change it —
    /// so it read like a control and was not one. It is now both explicit and configurable, with a
    /// missing key resolving to <see cref="AiBudgetUncoveredBehaviour.Refuse"/> and an unrecognised one
    /// refusing the load rather than silently defaulting.
    /// </para>
    /// </remarks>
    public AiBudgetUncoveredBehaviour OnUnpricedExecution { get; init; } = AiBudgetUncoveredBehaviour.Refuse;

    /// <summary>The shipped policy: available, no rules, and an uncovered priced execution is refused.</summary>
    /// <remarks>
    /// Fail-closed, matching the governance plane's own posture. On the committed estate this changes
    /// nothing observable, because the governance budget table is likewise empty and already refuses
    /// every priced route with <see cref="AiGovernanceRules.BudgetUncovered"/>.
    /// </remarks>
    public static AiOperationsBudgetPolicy Default { get; } = new();

    /// <summary>
    /// The operational budget plane is not evaluated. An explicit posture, not a default.
    /// </summary>
    /// <remarks>
    /// <b>This is a widening, and it is spelled out rather than reached by leaving a list empty.</b>
    /// An estate that uses it is stating that its only cost gate is the governance budget table. It
    /// exists because the two planes are genuinely separable — one is a policy ceiling evaluated
    /// before routing, the other is a spend ceiling evaluated against what has already been spent —
    /// and an estate may legitimately run the first without the second.
    /// </remarks>
    public static AiOperationsBudgetPolicy NotEvaluated { get; } = new()
    {
        Available = false,
        OnUncoveredPricedExecution = AiBudgetUncoveredBehaviour.Allow,
    };

    /// <summary>The most specific rule covering a context, or null when none does.</summary>
    /// <remarks>
    /// Ordered by specificity and then by rule identifier, never by declaration order: a budget
    /// table whose meaning depends on which line came first is a table nobody can review, and an
    /// edit that reordered two rules would change what the estate may spend with no diff on the
    /// ceiling values.
    /// </remarks>
    public AiOperationsBudgetRule? RuleFor(AiBudgetContext context)
    {
        ArgumentNullException.ThrowIfNull(context);

        return Rules
            .Where(rule => rule.Applies(context))
            .OrderByDescending(rule => rule.Specificity)
            .ThenBy(rule => rule.RuleId, StringComparer.Ordinal)
            .FirstOrDefault();
    }

    /// <summary>
    /// Validates the policy, throwing on the first defect.
    /// </summary>
    /// <exception cref="ArgumentException">A rule is malformed, duplicated or permits what it bounds.</exception>
    public void Validate()
    {
        ArgumentNullException.ThrowIfNull(Rules);

        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (var rule in Rules)
        {
            if (rule is null || !CapabilityId.IsValid(rule.RuleId))
            {
                throw new ArgumentException(
                    $"'{rule?.RuleId}' is not a valid budget rule identifier.", nameof(Rules));
            }

            if (!seen.Add(rule.RuleId))
            {
                throw new ArgumentException(
                    $"Budget rule identifier '{rule.RuleId}' is declared more than once. Two rules with one " +
                    "identity make a verdict's RuleId ambiguous, and the ambiguity is invisible in the table.",
                    nameof(Rules));
            }

            if (rule.Ceiling < 0m)
            {
                throw new ArgumentException(
                    $"Budget rule '{rule.RuleId}' has a negative ceiling. A negative ceiling is not a budget, " +
                    "it is a rule that refuses everything priced at all, expressed as arithmetic.",
                    nameof(Rules));
            }

            if (string.IsNullOrWhiteSpace(rule.Currency))
            {
                throw new ArgumentException(
                    $"Budget rule '{rule.RuleId}' names no currency. A ceiling without a currency cannot be " +
                    "compared against a cost.",
                    nameof(Rules));
            }

            if (rule.OnExceeded is AiGovernanceVerdict.Allow)
            {
                throw new ArgumentException(
                    $"Budget rule '{rule.RuleId}' allows when its ceiling is exceeded. A ceiling that permits " +
                    "what exceeds it is not a control; it is a comment that reads like one.",
                    nameof(Rules));
            }

            if (string.IsNullOrWhiteSpace(rule.Rationale))
            {
                throw new ArgumentException(
                    $"Budget rule '{rule.RuleId}' has no rationale. A ceiling nobody explained cannot be " +
                    "reviewed when someone asks why it is where it is.",
                    nameof(Rules));
            }

            if (!Enum.IsDefined(rule.Period))
            {
                throw new ArgumentException(
                    $"Budget rule '{rule.RuleId}' names an undefined period '{rule.Period}'.", nameof(Rules));
            }

            if (!Enum.IsDefined(rule.OnExceeded))
            {
                throw new ArgumentException(
                    $"Budget rule '{rule.RuleId}' names an undefined verdict '{rule.OnExceeded}'.", nameof(Rules));
            }
        }

        if (!Enum.IsDefined(OnUncoveredPricedExecution))
        {
            throw new ArgumentException(
                $"The policy names an undefined uncovered-execution behaviour "
                + $"'{OnUncoveredPricedExecution}'.", nameof(OnUncoveredPricedExecution));
        }
    }
}

/// <summary>
/// Decides whether a proposed execution is within the estate's operational budget.
/// </summary>
/// <remarks>
/// <para>
/// <b>Deterministic and synchronous, because it is consulted inside routing.</b> The same context,
/// the same policy and the same committed spend produce the same verdict; the committed spend is
/// read from an in-process ledger rather than from a remote store, so there is no network inside a
/// routing decision here either.
/// </para>
/// <para>
/// <b>It can only ever refuse.</b> Budget is a gate, not a preference: a route is never selected
/// <em>because</em> it is cheap here. Cost preference lives in ranking, where it is a weight an
/// operator can set, and keeping the two apart is what stops a budget rule from silently becoming a
/// routing policy.
/// </para>
/// </remarks>
public interface IAiBudgetEvaluator
{
    /// <summary>Evaluates a proposed execution against the operational budget policy.</summary>
    AiBudgetDecision Evaluate(AiBudgetContext context);
}
