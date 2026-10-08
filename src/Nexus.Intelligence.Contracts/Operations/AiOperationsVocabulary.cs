namespace Nexus.Intelligence.Contracts;

/// <summary>
/// How usage and cost are grouped when read back.
/// </summary>
/// <remarks>
/// <para>
/// The dimensions are exactly the ones the identity data actually supports. A group-by the estate
/// cannot populate would return one bucket labelled "unknown" and read like a finding about the
/// estate when it is a finding about the enum.
/// </para>
/// <para>
/// <see cref="Execution"/> is the finest grain and the join key to everything else; the router and
/// the audit record both carry an execution identity, so every other dimension is derivation from
/// the same entry rather than a second write.
/// </para>
/// </remarks>
public enum AiUsageGroupBy
{
    /// <summary>One bucket per execution. The finest grain, and the audit join key.</summary>
    Execution = 0,

    /// <summary>By the capability served.</summary>
    Capability = 1,

    /// <summary>By the model that served it. Operational attribution, never a caller preference.</summary>
    Model = 2,

    /// <summary>By the provider that served it.</summary>
    Provider = 3,

    /// <summary>By the calling product, where the caller named one.</summary>
    Product = 4,

    /// <summary>By tenant, where the caller named one.</summary>
    Tenant = 5,

    /// <summary>By workspace, where the caller named one.</summary>
    Workspace = 6,

    /// <summary>By the end user or service principal the work was done for.</summary>
    Principal = 7,
}

/// <summary>
/// Whether a cost figure is a prediction or a measurement.
/// </summary>
/// <remarks>
/// <para>
/// <b>The two are not interchangeable, and an operations surface that conflates them is wrong in
/// the direction that matters.</b> An estimate is what a budget decision rests on; an actual is what
/// an invoice reconciles against. Averaging them together produces a number that is neither a
/// forecast nor a record of spend, and the error is invisible because both look like money.
/// </para>
/// <para>
/// <see cref="Unpriced"/> is a first-class member rather than a zero. A model with no rates yields
/// no figure at all, and writing <c>0</c> for it would state that the execution was free — which is
/// the one thing an unpriced execution certainly is not.
/// </para>
/// </remarks>
public enum AiCostBasis
{
    /// <summary>No price was available. The amount is absent, not zero.</summary>
    Unpriced = 0,

    /// <summary>Predicted before the provider call, from the registry's pricing metadata.</summary>
    Estimated = 1,

    /// <summary>Computed after the call from the observed token counts the provider reported.</summary>
    ActualRecorded = 2,
}

/// <summary>
/// Which lifetime a budget ceiling is measured over.
/// </summary>
public enum AiBudgetPeriod
{
    /// <summary>The ceiling bounds this execution alone.</summary>
    None = 0,

    /// <summary>The ceiling bounds cumulative spend over the current UTC day.</summary>
    Daily = 1,

    /// <summary>The ceiling bounds cumulative spend over the current UTC calendar month.</summary>
    Monthly = 2,
}

/// <summary>
/// The scoped dimension an operational budget rule is keyed on, derived from which scope fields it
/// sets.
/// </summary>
/// <remarks>
/// Derived rather than declared, so a rule cannot claim a scope it does not actually narrow. A rule
/// whose declared scope disagreed with its populated fields would be a table entry that reads as
/// narrower than it is.
/// </remarks>
public enum AiBudgetScope
{
    /// <summary>No scope field set. Bounds every matched execution.</summary>
    Unscoped = 0,

    /// <summary>Bounded to a capability.</summary>
    Capability = 1,

    /// <summary>Bounded to a product.</summary>
    Product = 2,

    /// <summary>Bounded to a tenant.</summary>
    Tenant = 3,

    /// <summary>Bounded to a workspace.</summary>
    Workspace = 4,

    /// <summary>Bounded to a provider.</summary>
    Provider = 5,

    /// <summary>Bounded to a model.</summary>
    Model = 6,
}

/// <summary>
/// What happens when a priced execution has no covering operational budget rule.
/// </summary>
/// <remarks>
/// <b>There is no default that is also a silence.</b> The directive is explicit that a missing
/// policy must follow the configured rule rather than being read as unlimited, so the behaviour is
/// a named member of the policy record and an estate states which one it means. The shipped
/// default is <see cref="Refuse"/>, because "no ceiling covers this" and "this has no ceiling" are
/// the same statement and the second is a finding.
/// </remarks>
public enum AiBudgetUncoveredBehaviour
{
    /// <summary>Refuse. The shipped default.</summary>
    Refuse = 0,

    /// <summary>Permit, explicitly. An estate that has consciously not configured this plane.</summary>
    Allow = 1,
}

/// <summary>
/// What the operational budget gate concluded about one route, as a member rather than as prose.
/// </summary>
/// <remarks>
/// <para>
/// <b>W7F TASK 4. Before this enum the gate's answer was readable only from a pair of members that
/// did not distinguish its cases.</b> An execution the gate never priced, an execution with no policy
/// composed, and an execution a covering rule permitted all arrived as the same
/// <c>{ Verdict = Allow, RuleId = null }</c> — and the caller had to consult the execution's overall
/// status to guess which it was looking at. That is the ambiguity the directive names, and guessing
/// from status is wrong precisely where it matters: an invocation gate can refuse a route the budget
/// gate permitted, and a reader who inferred "the budget refused this" from a blocked status would
/// attribute a policy outcome to the wrong policy.
/// </para>
/// <para>
/// <b>An allow is not a claim that money was measured.</b> <see cref="WithinCeiling"/> says a ceiling
/// was compared and satisfied. <see cref="Unpriced"/>, <see cref="AllowedUncovered"/> and
/// <see cref="NotConfigured"/> all permit, and none of them says anything about an amount. A reader
/// that treated them as coverage would be reading a permission as a measurement.
/// </para>
/// <para>
/// <b>Append-only.</b> Members are added at the end and never renumbered: this vocabulary is carried
/// on the audit and operations surfaces, where a renumbered member silently reinterprets records the
/// estate has already written.
/// </para>
/// </remarks>
public enum AiBudgetOutcome
{
    /// <summary>
    /// The gate reached no conclusion about this route, because it was never asked.
    /// </summary>
    NotEvaluated = 0,

    /// <summary>
    /// No operational budget plane is composed, so no evaluation happened and none was intended.
    /// </summary>
    /// <remarks>
    /// Distinct from <see cref="AllowedUncovered"/>: that is a gate which ran, found no covering rule,
    /// and was configured to permit. This is a gate that does not exist. Both permit, and only one of
    /// them is a fact about the budget table.
    /// </remarks>
    NotConfigured = 1,

    /// <summary>
    /// The route has no projected cost, so there was no figure to compare against any ceiling.
    /// </summary>
    /// <remarks>
    /// <b>Permitted, and emphatically not priced.</b> The gate has nothing to say about an amount it
    /// does not have, and says so here rather than in a zero. An estate that requires every route it
    /// runs to be priceable states that through
    /// <see cref="AiOperationsBudgetPolicy.OnUnpricedExecution"/>; the shipped posture leaves this
    /// case to the governance plane's own cost gate, which is where "this estate does not run work it
    /// cannot price" is already expressible.
    /// </remarks>
    Unpriced = 2,

    /// <summary>A covering rule matched and the projection is inside its ceiling.</summary>
    WithinCeiling = 3,

    /// <summary>
    /// The route is priced and no rule covers it, and the configured behaviour permits it.
    /// </summary>
    AllowedUncovered = 4,

    /// <summary>
    /// The route is priced and no rule covers it, and the configured behaviour refuses it.
    /// </summary>
    /// <remarks>
    /// The shipped default for an uncovered priced execution. <see cref="AiBudgetDecision.RuleId"/> is
    /// null here by definition — no rule refused this — which is why the rule identifier alone could
    /// not carry this outcome's meaning.
    /// </remarks>
    RefusedUncovered = 5,

    /// <summary>
    /// A covering rule matched and the projection exceeds its ceiling.
    /// </summary>
    /// <remarks>
    /// The finding, not the rule's response to it. A ceiling's
    /// <see cref="AiOperationsBudgetRule.OnExceeded"/> decides whether the verdict blocks or escalates,
    /// and the verdict member carries that; what is recorded here is the fact both responses are
    /// responses to. Naming it after the escalation as well would make an escalated execution
    /// indistinguishable at this member from one that was never measured.
    /// </remarks>
    RefusedOverCeiling = 6,

    /// <summary>
    /// A covering rule exists but is denominated differently from the execution, so nothing can be
    /// compared.
    /// </summary>
    /// <remarks>
    /// A refusal rather than a pass. A ceiling is a number with a unit, and two numbers in different
    /// units have no ordering — reading the mismatch as "within budget" would enforce nothing while
    /// reporting that a ceiling had been applied.
    /// </remarks>
    CurrencyMismatch = 7,

    /// <summary>
    /// A covering rule bounds a period and no cost ledger is available to measure that period.
    /// </summary>
    /// <remarks>
    /// A refusal rather than a fallback to a per-execution comparison, because the two are different
    /// controls and silently substituting one for the other would enforce a ceiling nobody wrote.
    /// </remarks>
    WindowUnmeasurable = 8,

    /// <summary>
    /// The route has no projected cost and the estate requires every route it runs to be priceable.
    /// </summary>
    /// <remarks>
    /// The fail-closed counterpart of <see cref="Unpriced"/>, and a refusal for the same reason
    /// <see cref="RefusedUncovered"/> is one: a route whose cost nobody can state is not a route whose
    /// cost is zero.
    /// </remarks>
    RefusedUnpriced = 9,
}

/// <summary>
/// Which budget decision an operations view's budget members report.
/// </summary>
/// <remarks>
/// <para>
/// <b>W7F TASK 4.</b> One execution can carry more than one budget decision — the route that was
/// selected has its own, and every route the ceiling refused has one too — so a view that published a
/// single verdict without saying which decision produced it left the reader to work it out from the
/// execution's status. The read model has always chosen correctly; this member states the choice
/// instead of leaving it to be inferred.
/// </para>
/// <para>
/// <b>An execution can carry a refusal decision it did not act on.</b> A route the ceiling refused
/// while another route served is a real finding recorded in the router's rejections, and it is
/// deliberately not reported here — an execution that succeeded did not fail its budget.
/// </para>
/// <para>
/// <b>"Selected" means the route the router selected, which is not always the route that served.</b>
/// The operational gates run inside routing, so the verdict they produce is about the candidate the
/// router chose; a failover afterwards can put the work on a different route entirely. Where that
/// happens the two are reconciled by
/// <see cref="AiExecutionOperationsView.BudgetSubstitution"/>, and the divergence is exactly what it
/// exists to state. Reading this member as "the route named on the view's own route fields" would
/// misattribute a verdict about one route to another.
/// </para>
/// </remarks>
public enum AiBudgetReading
{
    /// <summary>No budget decision is reported. The gate did not run, or recorded nothing.</summary>
    None = 0,

    /// <summary>
    /// The decision is the one made about the route the router selected — which is the route the
    /// operational gates evaluated, and not necessarily the route that served.
    /// </summary>
    SelectedRoute = 1,

    /// <summary>The decision is the one that refused the execution, recorded because nothing was selected.</summary>
    Refusal = 2,
}

/// <summary>
/// The processing tier a route is evaluated against.
/// </summary>
/// <remarks>
/// <para>
/// <b>Reused from the estate's existing routing plane rather than invented here.</b> The AI Head has
/// carried these four tiers since the routing unit was imported, and a second vocabulary naming the
/// same four things is how a system acquires two answers to one question.
/// </para>
/// <para>
/// A tier is <b>declared metadata on the model registration</b>, never inferred. It is not
/// derivation from a model identifier, a provider name or a price: a rule that read "GPT" to decide
/// a model supports batch pricing would be a rule that silently mis-classifies the next model whose
/// vendor happens to be spelled similarly.
/// </para>
/// </remarks>
public enum AiProcessingTier
{
    /// <summary>Interactive, on-demand processing. Every model supports this.</summary>
    Standard = 0,

    /// <summary>Deferred bulk processing, typically at a discount and with a longer deadline.</summary>
    Batch = 1,

    /// <summary>Flexible processing: lower cost, slower, and interruptible.</summary>
    Flex = 2,

    /// <summary>Expedited processing, typically at a premium.</summary>
    Priority = 3,
}

/// <summary>
/// Where a price quote stands, as the catalogue knows it.
/// </summary>
public enum AiPricingStatus
{
    /// <summary>Current and usable.</summary>
    Current = 0,

    /// <summary>Still readable, flagged for review. Usable, and reported as flagged.</summary>
    NeedsReview = 1,

    /// <summary>Out of date. Usable only where the policy permits, and always reported.</summary>
    Expired = 2,

    /// <summary>An operator overrode the published price deliberately.</summary>
    ManualOverride = 3,
}

/// <summary>The outcome of a price lookup, including the ways it can fail.</summary>
/// <remarks>
/// <see cref="NotFound"/> and <see cref="Ambiguous"/> are separate members because the responses
/// differ: a missing price is a configuration gap, an ambiguous one is a configuration defect. A
/// single "unavailable" would collapse a gap and a defect into one operational signal.
/// </remarks>
public enum AiPricingLookupState
{
    /// <summary>Exactly one usable quote matched.</summary>
    Found = 0,

    /// <summary>No quote matched.</summary>
    NotFound = 1,

    /// <summary>More than one quote matched and the catalogue will not guess between them.</summary>
    Ambiguous = 2,

    /// <summary>A quote matched but is expired, and the policy does not permit its use.</summary>
    Expired = 3,
}

/// <summary>
/// Why a failover moved, or declined to move, at one step.
/// </summary>
/// <remarks>
/// <para>
/// <b>A closed vocabulary, reused from the estate's existing failover contract.</b> The reason codes
/// are the ones the routing unit already defines, because an operator reading a failover incident
/// must not have to know which of two planes produced the line they are looking at.
/// </para>
/// <para>
/// <see cref="GovernanceBlockNotFailover"/> is the load-bearing member. A governance refusal is
/// <b>not</b> a failover trigger: falling back from a model governance blocked would convert a
/// policy refusal into a silent search for a model policy had not yet refused, which is the failure
/// mode the whole governed path exists to prevent. It is named here so that the correct behaviour
/// has a code and does not need a comment in a router to be legible.
/// </para>
/// </remarks>
public enum AiFailoverReasonCode
{
    /// <summary>The primary route was healthy and was used. No failover was attempted.</summary>
    HealthyRoute = 0,

    /// <summary>The primary route was unhealthy before invocation; failover was considered.</summary>
    RouteUnhealthy = 1,

    /// <summary>A usable alternate was found and selected.</summary>
    HealthyAlternateFound = 2,

    /// <summary>No usable alternate existed. The failure stands.</summary>
    NoHealthyAlternate = 3,

    /// <summary>An alternate existed but the router's own gates had already refused it.</summary>
    AlternateRejectedByRouter = 4,

    /// <summary>An alternate was refused because it would exceed a budget ceiling.</summary>
    AlternateOverBudget = 5,

    /// <summary>An alternate was permitted against a budget it satisfies.</summary>
    AlternateBudgetOk = 6,

    /// <summary>An alternate's cost could not be determined, so it was not selected.</summary>
    AlternateBudgetUnknown = 7,

    /// <summary>An alternate is over budget and the covering rule escalates to a human.</summary>
    BudgetRequiresOverride = 8,

    /// <summary>An alternate was refused on observed reliability evidence.</summary>
    AlternateReliabilityTooLow = 9,

    /// <summary>The provider reports an authentication fault; a human must act. Not retryable.</summary>
    AuthRequiresHuman = 10,

    /// <summary>The provider is disabled in the registry.</summary>
    ProviderDisabled = 11,

    /// <summary>An alternate's health is unknown, which is not the same as healthy.</summary>
    HealthUnknown = 12,

    /// <summary>An alternate was refused for a processing-tier mismatch.</summary>
    AlternateTierUnsupported = 13,

    /// <summary>The failure is not one a retry can plausibly resolve.</summary>
    FailureNotRetryable = 14,

    /// <summary>Governance refused. Failover does not apply to a policy refusal.</summary>
    GovernanceBlockNotFailover = 15,

    /// <summary>The configured fallback depth was already consumed.</summary>
    FallbackDepthExhausted = 16,

    /// <summary>The primary failed and the next alternate is being attempted.</summary>
    AttemptingAlternate = 17,

    /// <summary>An alternate succeeded.</summary>
    AlternateSucceeded = 18,

    /// <summary>An alternate was attempted and failed, with a retryable category.</summary>
    AlternateFailed = 19,
}

/// <summary>
/// How a health probe concluded about one target.
/// </summary>
/// <remarks>
/// Distinct from <see cref="AiModelHealthState"/> on purpose. The state is what routing reads; this
/// is what the probe observed, and it includes the two outcomes that are not health states at all:
/// the probe did not run, or it ran and could not conclude. Collapsing those into
/// <see cref="AiModelHealthState.Unknown"/> would make "we never asked" and "we asked and the answer
/// was unusable" the same operational fact.
/// </remarks>
public enum AiHealthProbeOutcome
{
    /// <summary>The probe ran and produced a definite state.</summary>
    Observed = 0,

    /// <summary>The probe ran and could not conclude. The published state stays as it was.</summary>
    Inconclusive = 1,

    /// <summary>No probe is configured for this target. The declared state is published unchanged.</summary>
    NotProbed = 2,
}
