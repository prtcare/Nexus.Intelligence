namespace Nexus.Intelligence.Contracts;

/// <summary>
/// What an operator asks the operations surface. Every filter is optional.
/// </summary>
public sealed record AiOperationsQuery
{
    /// <summary>Restrict to one execution.</summary>
    public string? ExecutionId { get; init; }

    /// <summary>Restrict to one caller request.</summary>
    public string? RequestId { get; init; }

    /// <summary>Restrict to one capability.</summary>
    public CapabilityId? Capability { get; init; }

    /// <summary>Restrict to one provider.</summary>
    public string? ProviderId { get; init; }

    /// <summary>Restrict to one model.</summary>
    public string? ModelId { get; init; }

    /// <summary>Restrict to one product.</summary>
    public string? ProductId { get; init; }

    /// <summary>Restrict to one tenant.</summary>
    public string? TenantId { get; init; }

    /// <summary>Restrict to entries recorded at or after this instant.</summary>
    public DateTimeOffset? From { get; init; }

    /// <summary>Restrict to entries recorded strictly before this instant.</summary>
    public DateTimeOffset? To { get; init; }

    /// <summary>Restrict to executions whose status is one of these. Empty means no restriction.</summary>
    public IReadOnlyList<AiExecutionStatus> StatusIn { get; init; } = [];

    /// <summary>Restrict to executions whose failure category is one of these. Empty means no restriction.</summary>
    public IReadOnlyList<AiFailureCategory> FailureCategoryIn { get; init; } = [];

    /// <summary>Restrict to executions that used a fallback route, or to those that did not.</summary>
    public bool? UsedFallback { get; init; }

    /// <summary>
    /// How many items at most to return: execution views for an execution read, buckets for a rollup.
    /// Null means no limit.
    /// </summary>
    /// <remarks>
    /// Applied after filtering and after ordering, so it takes the most recent <c>n</c> of what
    /// matched rather than the first <c>n</c> of everything. A limit applied before ordering would make
    /// the result depend on storage order, which is how "the last twenty failures" becomes "twenty
    /// records, some of which are failures".
    /// </remarks>
    public int? Limit { get; init; }
}

/// <summary>
/// One execution as an operator sees it: status, route, health, cost, latency, outcome.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is a read model, not a live handle.</b> It is assembled at read time from the audit
/// record, the usage and cost ledgers, and the failover record. Nothing in it is a reference to a
/// mutable object, so a consumer cannot accidentally observe the estate changing underneath it —
/// and Atlas, when it consumes this, cannot reach an internal provider state through it.
/// </para>
/// <para>
/// <b>Provider and model are present here and are not on any caller-facing type.</b> The operations
/// surface is an operator surface under authority; a Product does not receive it. That is the same
/// arrangement the audit record already makes, and it is why this type lives beside the audit
/// vocabulary rather than beside the capability contracts.
/// </para>
/// </remarks>
public sealed record AiExecutionOperationsView
{
    /// <summary>The AI Head's identifier for this execution.</summary>
    public required string ExecutionId { get; init; }

    /// <summary>The caller's request identifier.</summary>
    public required string RequestId { get; init; }

    /// <summary>Correlates across services.</summary>
    public required string CorrelationId { get; init; }

    /// <summary>What was asked for.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>
    /// The principal the work was done for. Present whenever an audit record exists, which is the
    /// spine this view is built from.
    /// </summary>
    public string? PrincipalId { get; init; }

    /// <summary>The product the work was attributed to, where the caller named one.</summary>
    public string? ProductId { get; init; }

    /// <summary>The tenant the work was attributed to, where the caller named one.</summary>
    public string? TenantId { get; init; }

    /// <summary>The workspace the work was attributed to, where the caller named one.</summary>
    public string? WorkspaceId { get; init; }

    /// <summary>How the execution ended.</summary>
    public required AiExecutionStatus Status { get; init; }

    /// <summary>The failure category, when it did not succeed.</summary>
    public AiFailureCategory? FailureCategory { get; init; }

    /// <summary>The caller-safe failure code, when it did not succeed.</summary>
    public string? FailureCode { get; init; }

    /// <summary>The provider that served it, or that would have.</summary>
    public string? ProviderId { get; init; }

    /// <summary>The model that served it, or that would have.</summary>
    public string? ModelId { get; init; }

    /// <summary>How the model's health was reported at the time.</summary>
    public AiModelHealthState? ModelHealth { get; init; }

    /// <summary>How the provider's health was reported at the time.</summary>
    public AiModelHealthState? ProviderHealth { get; init; }

    /// <summary>
    /// The chosen route's circuit state as the recovery gate read it, where the model applied.
    /// </summary>
    /// <remarks>
    /// Carried whole rather than flattened into a state column, because every member of the snapshot is
    /// a question an operator asks next: which failure opened it, when the cooldown ends, how much probe
    /// traffic is left, and whether the failures that caused it are still on the record. A row that
    /// published only the state would send the reader to the logs for all four.
    /// </remarks>
    public AiCircuitSnapshot? Circuit { get; init; }

    /// <summary>Whether this execution was a probationary probe rather than ordinary capacity.</summary>
    public bool IsProbe { get; init; }

    /// <summary>True when the execution used a fallback route.</summary>
    public bool UsedFallback { get; init; }

    /// <summary>Why the failover stopped, where a failover ran.</summary>
    public AiFailoverReasonCode? FailoverReasonCode { get; init; }

    /// <summary>Every route the failover considered, where a failover ran.</summary>
    public IReadOnlyList<AiFailoverAttempt> FailoverAttempts { get; init; } = [];

    /// <summary>How many routes were eligible and how many were refused, as the router saw it.</summary>
    public int EligibleRoutes { get; init; }

    /// <summary>How many routes the router refused.</summary>
    public int RejectedRoutes { get; init; }

    /// <summary>Every route the router refused, with the gate that refused it.</summary>
    public IReadOnlyList<AiRoutingRejection> RoutingRejections { get; init; } = [];

    /// <summary>Input tokens consumed.</summary>
    public int TokensIn { get; init; }

    /// <summary>Output tokens produced.</summary>
    public int TokensOut { get; init; }

    /// <summary>Total tokens.</summary>
    public int TotalTokens => TokensIn + TokensOut;

    /// <summary>The authoritative cost, where a price was available.</summary>
    public decimal? Cost { get; init; }

    /// <summary>The currency <see cref="Cost"/> is in.</summary>
    public string? Currency { get; init; }

    /// <summary>Whether <see cref="Cost"/> is a prediction or a measurement.</summary>
    public AiCostBasis CostBasis { get; init; } = AiCostBasis.Unpriced;

    /// <summary>Total elapsed time, where measured.</summary>
    public TimeSpan? Latency { get; init; }

    /// <summary>What governance concluded, as rules applied.</summary>
    public IReadOnlyList<string> GovernanceRules { get; init; } = [];

    /// <summary>True when governance permitted the execution.</summary>
    public bool GovernanceAllowed { get; init; }

    /// <summary>
    /// What the operational budget gate concluded, where it reached a verdict about this execution.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>W7F TASK 4: read <see cref="BudgetReading"/> for which decision this is, and
    /// <see cref="Budget"/> for what it concluded.</b> Until W7F a consumer had to work both out from
    /// the execution's own status, which was wrong in two directions at once: it could not tell a
    /// verdict about the route that served from a verdict that refused the execution without reading a
    /// second member, and it attributed a policy outcome to the budget gate whenever any gate had
    /// blocked. Both readings are now stated rather than inferred.
    /// </para>
    /// <para>
    /// <b>Two readings survive, and they are genuinely two.</b> On an execution that reached a route,
    /// this is the verdict on the route that served it — including where a later gate, not this one,
    /// refused the invocation. On a refusal where nothing was selected, it is the verdict that refused,
    /// because a refused execution selected no route and the decision an operator wants is the one that
    /// stopped it.
    /// </para>
    /// <para>
    /// Null when the gate did not reach a verdict: the operational stage did not run, or the execution
    /// was never priced. Null is not an allow, and a consumer that read it as one would treat an
    /// unmeasured execution as a permitted one.
    /// </para>
    /// </remarks>
    public AiGovernanceVerdict? BudgetVerdict { get; init; }

    /// <summary>
    /// Which budget decision <see cref="Budget"/>, <see cref="BudgetVerdict"/> and
    /// <see cref="BudgetRuleId"/> report.
    /// </summary>
    /// <remarks>
    /// <b>W7F TASK 4, and the member that removes the inference.</b> A consumer that needs to know
    /// whether it is looking at the serving route's evaluation or at the decision that refused the
    /// execution reads this and nothing else. <see cref="AiBudgetReading.None"/> means the members
    /// beside it are null because no decision was recorded, not because one was recorded and found
    /// nothing to say — that case is <see cref="AiBudgetOutcome.Unpriced"/> on a populated
    /// <see cref="Budget"/>.
    /// </remarks>
    public AiBudgetReading BudgetReading { get; init; } = AiBudgetReading.None;

    /// <summary>
    /// The whole decision the members above project.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>W7F TASK 4.</b> The verdict and the rule identifier are the two fields an operator looks at
    /// most, and they were the only two this view carried — which is how a decision came to be
    /// reported by two of its parts. The decision itself is what the gate reached, including the
    /// outcome member that says which conclusion it is, the scope and window it measured over, and the
    /// projection and committed spend it rested on. Carried whole so that a reader cannot hold a
    /// verdict while being unable to say what produced it.
    /// </para>
    /// <para>
    /// <see cref="BudgetVerdict"/> and <see cref="BudgetRuleId"/> are written from this same decision
    /// and cannot disagree with it; a test asserts that rather than trusting it.
    /// </para>
    /// </remarks>
    public AiBudgetDecision? Budget { get; init; }

    /// <summary>The budget rule that produced <see cref="BudgetVerdict"/>, where one did.</summary>
    /// <remarks>
    /// Null is not self-describing — <see cref="AiBudgetOutcome.RefusedUncovered"/> has no rule to name
    /// and neither does <see cref="AiBudgetOutcome.Unpriced"/> — so read <see cref="Budget"/> for the
    /// reason this is null rather than assuming there was no ceiling.
    /// </remarks>
    public string? BudgetRuleId { get; init; }

    /// <summary>
    /// The priced route a failover replaced with an unpriced one, where it did.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>W7F TASK 5.</b> Non-null means the ceilings this estate wrote were measured against a route
    /// that did not serve and the route that did serve has no price, so <see cref="Cost"/> is absent
    /// for that reason and not because the work was free. A reader that saw the absent cost without
    /// this would have no way to tell a substitution from a model whose rates nobody published.
    /// </para>
    /// <para>
    /// <b>Where this is present, <see cref="Budget"/> is the decision about the route its
    /// <c>From</c> members name — not about the route in <see cref="ModelId"/>, which is the one that
    /// served.</b> The operational gates run inside routing, so their verdict is necessarily about the
    /// candidate the router selected, and a failover can move the work afterwards. That divergence is
    /// the whole subject of this member; a reader who took the budget verdict for a statement about
    /// <see cref="ModelId"/> would be reading a verdict about one route as if it were about another.
    /// </para>
    /// </remarks>
    public AiBudgetSubstitution? BudgetSubstitution { get; init; }

    /// <summary>The processing tier the execution ran under.</summary>
    public AiProcessingTier Tier { get; init; } = AiProcessingTier.Standard;

    /// <summary>When the execution completed.</summary>
    public required DateTimeOffset Timestamp { get; init; }

    /// <summary>The audit record for this execution. The evidence, resolvable under authority.</summary>
    public required string AuditReference { get; init; }
}

/// <summary>
/// A rollup of executions over a window, grouped by one dimension.
/// </summary>
public sealed record AiOperationsSummary
{
    /// <summary>The dimension the buckets are keyed by.</summary>
    public required AiUsageGroupBy GroupBy { get; init; }

    /// <summary>The buckets, ordered by key ordinal so two identical reads produce identical output.</summary>
    public IReadOnlyList<AiOperationsBucket> Buckets { get; init; } = [];

    /// <summary>Total executions across every bucket.</summary>
    public int Executions => Buckets.Sum(b => b.Executions);

    /// <summary>Executions across every bucket that had no price at all.</summary>
    /// <remarks>
    /// <b>W7F TASK 5.</b> The rollup's version of the same warning the bucket carries: the summed
    /// <see cref="AiOperationsBucket.Cost"/> is a total over the priced executions, and this says how
    /// many were left out of it.
    /// </remarks>
    public int UnpricedExecutions => Buckets.Sum(b => b.UnpricedExecutions);
}

/// <summary>One bucket of an operations rollup.</summary>
public sealed record AiOperationsBucket
{
    /// <summary>The grouping key.</summary>
    public required string Key { get; init; }

    /// <summary>How many executions fell in this bucket.</summary>
    public required int Executions { get; init; }

    /// <summary>How many succeeded.</summary>
    public int Succeeded { get; init; }

    /// <summary>How many failed.</summary>
    public int Failed { get; init; }

    /// <summary>How many were refused by policy before reaching a provider.</summary>
    public int Blocked { get; init; }

    /// <summary>How many used a fallback route.</summary>
    public int FallbackExecutions { get; init; }

    /// <summary>Total tokens.</summary>
    public int TotalTokens { get; init; }

    /// <summary>Total authoritative cost, over the executions in this bucket that had a price.</summary>
    /// <remarks>
    /// <b>W7F TASK 5: it is a total over a subset, and <see cref="UnpricedExecutions"/> says how large
    /// the complement is.</b> The unpriced executions contribute nothing — not because their work was
    /// free but because the estate has no figure for it — and a reader that took this number alone
    /// would read a bucket of unpriceable work as a bucket that cost nothing.
    /// </remarks>
    public decimal Cost { get; init; }

    /// <summary>How many executions in this bucket had no price at all.</summary>
    /// <remarks>
    /// Counted on <see cref="AiCostBasis.Unpriced"/> rather than on a null cost, because the two are
    /// not the same fact: an execution whose entries are all unpriced has entries and an amount of
    /// zero, and an execution that reached no provider has neither.
    /// </remarks>
    public int UnpricedExecutions { get; init; }

    /// <summary>
    /// The currency <see cref="Cost"/> is in, or null when the bucket spans more than one.
    /// </summary>
    /// <remarks>
    /// Null is a warning rather than a gap: a bucket that mixed currencies has a <see cref="Cost"/>
    /// that must not be read as a single figure, and <see cref="Currencies"/> names what it actually
    /// contains. There is no exchange rate in this lane and inventing one would be inventing a
    /// business fact.
    /// </remarks>
    public string? Currency { get; init; }

    /// <summary>The distinct currencies present in the bucket.</summary>
    public IReadOnlyList<string> Currencies { get; init; } = [];

    /// <summary>Mean latency over the executions that measured one.</summary>
    public TimeSpan? AverageLatency { get; init; }

    /// <summary>Failure counts by category, ordered by category value.</summary>
    public IReadOnlyDictionary<AiFailureCategory, int> FailuresByCategory { get; init; }
        = new Dictionary<AiFailureCategory, int>();

    /// <summary>The observed success rate, or null when the bucket is empty.</summary>
    public double? SuccessRate => Executions == 0 ? null : (double)Succeeded / Executions;
}

/// <summary>
/// The operational read surface: request status, routing, health, fallback, tokens, cost, latency,
/// failure category and governance result, in one place.
/// </summary>
/// <remarks>
/// <para>
/// <b>It reads from records, not from internal provider state.</b> The directive asks for a read
/// surface rather than for consumers reaching into the router, the registry or a provider gateway,
/// and the difference is what keeps a later consumer from acquiring a dependency on an
/// implementation detail that a lane then cannot change.
/// </para>
/// <para>
/// <b>It reads the audit record for governance and outcome evidence, and the ledgers for spend.</b>
/// There is no second history: the audit record is the evidence, the usage ledger is the
/// consumption, the cost ledger is the spend, and this type joins them rather than keeping its own
/// copy. A second store would be a second source of truth and would disagree the first time one
/// write path failed.
/// </para>
/// <para>
/// <b>No consumer is coupled here.</b> Atlas and the Products consume this in a later lane through
/// an adapter that does not exist yet, and W7E does not write it.
/// </para>
/// </remarks>
public interface IAiOperationsReadModel
{
    /// <summary>One execution as an operator sees it, or null when nothing is known about it.</summary>
    AiExecutionOperationsView? Execution(string executionId);

    /// <summary>Executions matching a query, most recent first, bounded by the query's limit.</summary>
    IReadOnlyList<AiExecutionOperationsView> Executions(AiOperationsQuery query);

    /// <summary>A rollup matching a query, grouped by the requested dimension.</summary>
    AiOperationsSummary Summarize(AiOperationsQuery query, AiUsageGroupBy groupBy);
}
