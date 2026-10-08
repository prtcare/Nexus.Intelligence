namespace Nexus.Intelligence.Contracts;

/// <summary>
/// One governed execution's consumption, attributed to everything the estate can prove about it.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the operational record, and it is written once per provider invocation from the
/// governed path.</b> The Platform meter below it is not replaced and not duplicated: the meter
/// answers "what did the provider report", and this answers "what did the estate spend, on what, for
/// whom". The two are joined by <see cref="ExecutionId"/> rather than merged, because merging them
/// would require the Platform contract plane to know about AI routing identity, which it must not.
/// </para>
/// <para>
/// <b>Provider and model are recorded here as evidence of what served the request.</b> They are read
/// from the routing outcome, not from a caller and not from a second lookup. That is what makes
/// attribution reliable rather than reconstructed: the routing decision already knew the answer, and
/// this record is that answer, written once, at the moment it was still true.
/// </para>
/// <para>
/// <b>The estimate and the actual are both carried, and neither overwrites the other.</b> The
/// estimate is what a budget decision rested on; the actual is what the tokens observed. Keeping
/// both is what allows the estate to answer "is my pricing metadata right" — a question that is
/// unanswerable if only the survivor is stored.
/// </para>
/// </remarks>
public sealed record AiUsageEntry
{
    /// <summary>The AI Head's identifier for this execution. The join key to the audit record.</summary>
    /// <remarks>
    /// <b>W7F TASK 2: this is unique per execution and is not the caller's request identifier.</b>
    /// Until W7F the governed path wrote <see cref="RequestId"/> into this member, so two executions a
    /// caller considered "the same request" shared one execution identity — and, because the audit and
    /// evidence stores key on it, the second replaced the first. The two members now answer different
    /// questions and a reader must not substitute one for the other: a request identifier resolves to
    /// every execution that answered it, and an execution identity resolves to exactly one.
    /// </remarks>
    public required string ExecutionId { get; init; }

    /// <summary>The identity of the individual provider call that produced this entry.</summary>
    /// <remarks>
    /// <para>
    /// <b>W7F TASK 2.</b> An execution is not an invocation. One governed execution calls a provider
    /// once per attempt — the primary route, then each fallback the failover plane selects, then each
    /// further round the tool loop asks for — and every one of those calls is real spend recorded here
    /// separately. <see cref="ExecutionId"/> groups them; this member distinguishes them.
    /// </para>
    /// <para>
    /// <b>Before W7F this member was not needed, and its absence was not a gap.</b> With the execution
    /// identity collapsed onto the request identifier, a fallback's two attempts shared one execution
    /// identity <em>and</em> one request identity, so the pair identified nothing beyond "this
    /// request". With the execution identity corrected, (<see cref="ExecutionId"/>, this member) names
    /// exactly one provider call.
    /// </para>
    /// <para>
    /// <b>Required, and minted by the governed path rather than supplied by a caller.</b> An optional
    /// member would make "this entry belongs to an unnamed attempt" representable, and nothing in the
    /// estate writes such an entry: this ledger is written only by the AI Head's recorder, from a call
    /// site that knows the attempt it is recording. The numbering is ordinal within the execution and
    /// begins at one, and it advances only where an entry is written — so the attempts recorded for one
    /// execution are contiguous, and an attempt that consumed no tokens is absent from this ledger
    /// rather than present as a gap. What a refused route did is recorded in the execution evidence,
    /// which is the surface that has a field for it.
    /// </para>
    /// </remarks>
    public required string AttemptId { get; init; }

    /// <summary>The caller's request identifier.</summary>
    /// <remarks>
    /// The caller's correlation and idempotency identity, carried unchanged. It is what a caller
    /// searches by, and it may resolve to more than one execution.
    /// </remarks>
    public required string RequestId { get; init; }

    /// <summary>Correlates across services.</summary>
    public required string CorrelationId { get; init; }

    /// <summary>The capability that was served.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>The model that served it. Evidence, from the routing outcome.</summary>
    public required string ModelId { get; init; }

    /// <summary>The provider that served it. Evidence, from the routing outcome.</summary>
    public required string ProviderId { get; init; }

    /// <summary>The processing tier the execution ran under.</summary>
    public AiProcessingTier ProcessingTier { get; init; } = AiProcessingTier.Standard;

    /// <summary>True when this entry belongs to a fallback attempt rather than the primary route.</summary>
    /// <remarks>
    /// Carried so that a cost regression caused by failover is separable from one caused by the
    /// primary route. An operations surface that summed them would show a spend increase with no
    /// indication that it was a reliability incident.
    /// </remarks>
    public bool IsFallback { get; init; }

    /// <summary>The end user or service principal the work was done for, where the caller named one.</summary>
    public string? PrincipalId { get; init; }

    /// <summary>The calling product, where the caller named one.</summary>
    public string? ProductId { get; init; }

    /// <summary>The tenant, where the caller named one.</summary>
    public string? TenantId { get; init; }

    /// <summary>The workspace, where the caller named one.</summary>
    public string? WorkspaceId { get; init; }

    /// <summary>Input tokens consumed.</summary>
    public int TokensIn { get; init; }

    /// <summary>Output tokens produced.</summary>
    public int TokensOut { get; init; }

    /// <summary>Total tokens. Derived, so it cannot disagree with its parts.</summary>
    public int TotalTokens => TokensIn + TokensOut;

    /// <summary>What the execution was predicted to cost, where pricing metadata allowed a prediction.</summary>
    public decimal? EstimatedCost { get; init; }

    /// <summary>What the observed token counts cost, where pricing metadata allowed the computation.</summary>
    public decimal? ActualCost { get; init; }

    /// <summary>The currency both figures are in, or null when neither exists.</summary>
    public string? Currency { get; init; }

    /// <summary>Which of the two figures a reader should treat as authoritative, and why.</summary>
    public AiCostBasis CostBasis { get; init; } = AiCostBasis.Unpriced;

    /// <summary>The price quote that produced <see cref="EstimatedCost"/>, for reconciliation.</summary>
    public string? PriceQuoteId { get; init; }

    /// <summary>When the execution completed.</summary>
    public required DateTimeOffset RecordedAt { get; init; }

    /// <summary>The amount a reader should use, and null when the execution has no price at all.</summary>
    /// <remarks>
    /// Prefers the actual. Falls back to the estimate, and says so through <see cref="CostBasis"/>
    /// rather than silently — a caller reading a cost without reading the basis is reading a number
    /// whose meaning it has not established.
    /// </remarks>
    public decimal? AuthoritativeCost => CostBasis switch
    {
        AiCostBasis.ActualRecorded => ActualCost,
        AiCostBasis.Estimated => EstimatedCost,
        _ => null,
    };
}

/// <summary>
/// Which entries a read is asking for. Every filter is optional; an empty query is "everything".
/// </summary>
/// <remarks>
/// Filters are conjunctive and each unset filter means "do not narrow", never "match the null ones".
/// The distinction matters at exactly one place — a null <see cref="ProductId"/> must not select the
/// entries that have no product, because that would turn an unset filter into the narrowest possible
/// one and silently hide every attributed entry.
/// </remarks>
public sealed record AiUsageQuery
{
    /// <summary>Restrict to one execution.</summary>
    public string? ExecutionId { get; init; }

    /// <summary>Restrict to one caller request.</summary>
    public string? RequestId { get; init; }

    /// <summary>Restrict to one capability.</summary>
    public CapabilityId? Capability { get; init; }

    /// <summary>Restrict to one model.</summary>
    public string? ModelId { get; init; }

    /// <summary>Restrict to one provider.</summary>
    public string? ProviderId { get; init; }

    /// <summary>Restrict to one product.</summary>
    public string? ProductId { get; init; }

    /// <summary>Restrict to one tenant.</summary>
    public string? TenantId { get; init; }

    /// <summary>Restrict to one workspace.</summary>
    public string? WorkspaceId { get; init; }

    /// <summary>Restrict to entries recorded at or after this instant.</summary>
    public DateTimeOffset? From { get; init; }

    /// <summary>Restrict to entries recorded strictly before this instant.</summary>
    public DateTimeOffset? To { get; init; }

    /// <summary>How to group the result. <see cref="AiUsageGroupBy.Execution"/> is one bucket per entry.</summary>
    public AiUsageGroupBy GroupBy { get; init; } = AiUsageGroupBy.Execution;

    /// <summary>Every filter unset. Not the same as "no usage": it means "do not narrow".</summary>
    public static AiUsageQuery All { get; } = new();
}

/// <summary>One bucket of a usage read: an identity and the totals accumulated under it.</summary>
public sealed record AiUsageAggregate
{
    /// <summary>The grouping key, or the execution identifier when grouping by execution.</summary>
    public required string Key { get; init; }

    /// <summary>How many entries fell in this bucket.</summary>
    public required int Executions { get; init; }

    /// <summary>Total input tokens.</summary>
    public required int TokensIn { get; init; }

    /// <summary>Total output tokens.</summary>
    public required int TokensOut { get; init; }

    /// <summary>Total tokens.</summary>
    public int TotalTokens => TokensIn + TokensOut;

    /// <summary>Total authoritative cost across the bucket, in <see cref="Currency"/>.</summary>
    public required decimal Cost { get; init; }

    /// <summary>The currency <see cref="Cost"/> is in, or null when no entry in the bucket was priced.</summary>
    public string? Currency { get; init; }

    /// <summary>How many entries in the bucket had no price at all.</summary>
    /// <remarks>
    /// Reported alongside the total rather than folded into it. A bucket whose cost is a sum over
    /// four of its nine executions is not a cost, and a reader who cannot see the uncovered count
    /// will read it as one.
    /// </remarks>
    public int UnpricedExecutions { get; init; }

    /// <summary>How many entries in the bucket ran as a fallback attempt.</summary>
    public int FallbackExecutions { get; init; }
}

/// <summary>The result of a usage read: the buckets, and the totals over all of them.</summary>
public sealed record AiUsageReport
{
    /// <summary>The grouping the buckets are keyed by, echoed so a reader cannot misread a key.</summary>
    public required AiUsageGroupBy GroupBy { get; init; }

    /// <summary>The buckets, ordered by key ordinal so two identical reads produce identical output.</summary>
    public IReadOnlyList<AiUsageAggregate> Buckets { get; init; } = [];

    /// <summary>Total executions across every bucket.</summary>
    public int Executions => Buckets.Sum(b => b.Executions);

    /// <summary>Total input tokens across every bucket.</summary>
    public int TokensIn => Buckets.Sum(b => b.TokensIn);

    /// <summary>Total output tokens across every bucket.</summary>
    public int TokensOut => Buckets.Sum(b => b.TokensOut);

    /// <summary>Total tokens across every bucket.</summary>
    public int TotalTokens => TokensIn + TokensOut;

    /// <summary>Total authoritative cost across every bucket.</summary>
    public decimal Cost => Buckets.Sum(b => b.Cost);

    /// <summary>The distinct currencies present. More than one means the totals must not be added.</summary>
    /// <remarks>
    /// A count rather than a merged figure, because there is no exchange rate in this lane and
    /// inventing one would be inventing a business fact. A reader that sees two currencies knows to
    /// read the buckets, not the total.
    /// </remarks>
    public IReadOnlyList<string> Currencies { get; init; } = [];

    /// <summary>Executions across every bucket that had no price.</summary>
    public int UnpricedExecutions => Buckets.Sum(b => b.UnpricedExecutions);

    /// <summary>True when the report is over a single currency and its total is meaningful.</summary>
    public bool IsSingleCurrency => Currencies.Count <= 1;
}

/// <summary>
/// The operational usage read model: one write per invocation, many reads.
/// </summary>
/// <remarks>
/// <para>
/// <b>Write-once, and the write is not idempotent by accident.</b> Recording is called exactly once
/// per governed provider invocation, so a duplicate entry is a defect the estate can detect by
/// counting — which is why the count is asserted by test rather than assumed.
/// </para>
/// <para>
/// <b>Synchronous, deliberately.</b> The governed path records after the provider call has already
/// returned, so there is nothing to await; making the port asynchronous would invite a caller to
/// await it inside a routing decision, where no I/O may occur.
/// </para>
/// </remarks>
public interface IAiUsageLedger
{
    /// <summary>Records one execution's consumption. Called once per governed provider invocation.</summary>
    void Record(AiUsageEntry entry);

    /// <summary>Reads usage back, grouped and filtered. Never null; an empty report is a result.</summary>
    AiUsageReport Query(AiUsageQuery query);
}
