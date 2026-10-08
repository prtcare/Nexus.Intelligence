using System.Security.Cryptography;
using System.Text;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// What one governed provider invocation consumed and how it ended.
/// </summary>
/// <remarks>
/// <b>One of these per provider call, not per execution.</b> A fallback execution makes two calls and
/// consumes tokens on both, and the failed attempt's tokens are real spend. Recording once per
/// execution would lose them, and losing them would make a reliability incident look like a saving.
/// </remarks>
public sealed record AiInvocationFacts
{
    /// <summary>The execution this invocation belongs to. Shared across a fallback's attempts.</summary>
    public required string ExecutionId { get; init; }

    /// <summary>
    /// The identity of this individual call, unique within its execution.
    /// </summary>
    /// <remarks>
    /// <b>W7F TASK 2.</b> <see cref="ExecutionId"/> names the execution; this names the call. Every
    /// attempt an execution makes carries its own, so a usage entry is individually resolvable and a
    /// fallback's spend is attributable to the attempt that produced it rather than to the execution
    /// that contains it. It is minted by the caller of this method — the one place that knows which
    /// attempt is being recorded — and is copied onto the ledger entry unchanged, so the two records
    /// of one call cannot disagree about which call they describe.
    /// </remarks>
    public required string AttemptId { get; init; }

    /// <summary>The caller's request identifier.</summary>
    public required string RequestId { get; init; }

    /// <summary>Correlates across services.</summary>
    public required string CorrelationId { get; init; }

    /// <summary>The capability that was served.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>The requester, for attribution.</summary>
    public required AiRequesterIdentity Requester { get; init; }

    /// <summary>The model this invocation reached. Evidence, from the routing outcome.</summary>
    public required string ModelId { get; init; }

    /// <summary>The provider that served it. Evidence, from the routing outcome.</summary>
    public required string ProviderId { get; init; }

    /// <summary>The processing tier the invocation ran under.</summary>
    public AiProcessingTier Tier { get; init; } = AiProcessingTier.Standard;

    /// <summary>True when this invocation was a fallback attempt rather than the primary route.</summary>
    public bool IsFallback { get; init; }

    /// <summary>
    /// Input tokens the provider reported, or <c>null</c> when it reported no usage at all.
    /// </summary>
    /// <remarks>
    /// <b>Null means "we were told nothing", and it must survive to here.</b> The provider adapter is
    /// the only place that can observe the difference between a usage block that said zero and no usage
    /// block at all, and Platform's <c>ModelUsage</c> — which is non-nullable and defaults to zero —
    /// cannot carry it. So the adapter reports it out of band and it arrives here as null. Coercing it
    /// to zero at any point on the way makes an unmeasured execution indistinguishable from a measured
    /// one, and the cost basis below is derived from this value.
    /// </remarks>
    public required int? TokensIn { get; init; }

    /// <summary>
    /// Output tokens the provider reported, or <c>null</c> when it reported no usage at all.
    /// </summary>
    /// <remarks>Null together with <see cref="TokensIn"/> or not at all.</remarks>
    public required int? TokensOut { get; init; }

    /// <summary>What the route was predicted to cost before the call, where pricing metadata allowed it.</summary>
    public decimal? PreInvocationEstimate { get; init; }

    /// <summary>The currency the prediction was in, where there was one.</summary>
    public string? Currency { get; init; }

    /// <summary>The price quote the prediction used, where one was found.</summary>
    public string? PriceQuoteId { get; init; }

    /// <summary>Whether the invocation succeeded.</summary>
    public required bool Succeeded { get; init; }

    /// <summary>The failure category, when it did not succeed.</summary>
    public AiFailureCategory? FailureCategory { get; init; }

    /// <summary>How long the provider call took, where measured.</summary>
    public TimeSpan? Latency { get; init; }

    /// <summary>When the invocation completed.</summary>
    public required DateTimeOffset At { get; init; }
}

/// <summary>
/// Everything needed to write one execution's evidence and one execution's audit record.
/// </summary>
/// <remarks>
/// <b>Two records from one call, because they answer different questions.</b> The audit record is the
/// governance evidence — what was asked, what governed it, what served it, what it cost. The execution
/// evidence is what the routing and operational gates observed, including every route that was refused
/// and every fallback candidate that was skipped, none of which the audit record has a field for. Each
/// fact is written exactly once, in exactly one of them.
/// </remarks>
public sealed record AiExecutionFacts
{
    /// <summary>The AI Head's identifier for this execution.</summary>
    public required string ExecutionId { get; init; }

    /// <summary>The caller's request identifier.</summary>
    public required string RequestId { get; init; }

    /// <summary>Correlates across services.</summary>
    public required string CorrelationId { get; init; }

    /// <summary>The requester.</summary>
    public required AiRequesterIdentity Requester { get; init; }

    /// <summary>The capability that was requested.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>Why the caller said it was asking.</summary>
    public required string Purpose { get; init; }

    /// <summary>How the request was classified.</summary>
    public required DataClassification Classification { get; init; }

    /// <summary>The processing tier the work ran under.</summary>
    public AiProcessingTier Tier { get; init; } = AiProcessingTier.Standard;

    /// <summary>The context the execution was admitted, as references. Never the context itself.</summary>
    public IReadOnlyList<AiContextReference> ContextReferences { get; init; } = [];

    /// <summary>The route that served it, or that would have.</summary>
    public string? ProviderUsed { get; init; }

    /// <summary>The model that served it, or that would have.</summary>
    public string? ModelUsed { get; init; }

    /// <summary>The instruction set version applied, where one was.</summary>
    public string? PromptVersion { get; init; }

    /// <summary>The tools the execution invoked, by identifier.</summary>
    public IReadOnlyList<string> ToolsInvoked { get; init; } = [];

    /// <summary>
    /// Total input tokens across every invocation of this execution, or <c>null</c> when any invocation
    /// reported no usage.
    /// </summary>
    /// <remarks>A sum with an unknown part is unknown — see the token members on the usage entry.</remarks>
    public int? TokensIn { get; init; }

    /// <summary>Total output tokens across every invocation of this execution, or <c>null</c> when any did not report.</summary>
    /// <remarks>See <see cref="TokensIn"/>.</remarks>
    public int? TokensOut { get; init; }

    /// <summary>The execution's authoritative cost, where a price was available.</summary>
    public decimal? Cost { get; init; }

    /// <summary>The currency <see cref="Cost"/> is in.</summary>
    public string? Currency { get; init; }

    /// <summary>Whether <see cref="Cost"/> is a prediction or a measurement.</summary>
    public AiCostBasis CostBasis { get; init; } = AiCostBasis.Unpriced;

    /// <summary>Total elapsed time, where measured.</summary>
    public TimeSpan? Latency { get; init; }

    /// <summary>What governance decided about the execution as a whole.</summary>
    public required AiGovernanceDecision Decision { get; init; }

    /// <summary>The terminal status.</summary>
    public required AiExecutionStatus Status { get; init; }

    /// <summary>The failure category, when the execution did not succeed.</summary>
    public AiFailureCategory? FailureCategory { get; init; }

    /// <summary>A digest of the result, where one was produced and the classification permits it.</summary>
    public string? ResultHash { get; init; }

    /// <summary>A resolvable reference to the stored result, where one exists.</summary>
    public string? ResultReference { get; init; }

    /// <summary>The router's outcome, where routing ran.</summary>
    public AiRoutingOutcome? Routing { get; init; }

    /// <summary>The failover record, where the operational plane ran.</summary>
    public AiFailoverDecision? Failover { get; init; }

    /// <summary>When the execution completed.</summary>
    public required DateTimeOffset At { get; init; }
}

/// <summary>
/// Turns the governed path's facts into the four operational records the estate reads back.
/// </summary>
/// <remarks>
/// <para>
/// <b>It exists so the execution path stays a description of sequence.</b> Recording usage, cost,
/// reliability, routing evidence and an audit record is five writes with five shapes; inlined into
/// <c>GovernedTurnExecution</c> they would double its length and bury the stage order that is the file's
/// actual deliverable. The execution path gathers facts and hands them over.
/// </para>
/// <para>
/// <b>It computes the actual cost from the tokens the provider reported, against the configured
/// rate.</b> That is what makes <see cref="AiCostBasis.ActualRecorded"/> mean something: the prediction
/// was made from an estimated input size before the call, and the measurement is made from the real
/// counts after it, and the difference between them is the only evidence the estate has about whether
/// its pricing metadata and its token estimator are right.
/// </para>
/// <para>
/// <b>It never throws for a missing price.</b> An unpriced route records an entry with no cost and a
/// basis of <see cref="AiCostBasis.Unpriced"/>; the budget gate already refused it if policy required a
/// price, and a recorder that threw would convert a governance decision into an execution failure.
/// </para>
/// </remarks>
public sealed class AiOperationsRecorder
{
    private readonly IAiUsageLedger _usage;
    private readonly IAiPriceCatalogue _prices;
    private readonly IAiReliabilityHistory _reliability;
    private readonly IAiExecutionEvidenceStore _evidence;
    private readonly IAiAuditEmitter _audit;

    /// <summary>Builds the recorder from the stores it writes to.</summary>
    public AiOperationsRecorder(
        IAiUsageLedger usage,
        IAiPriceCatalogue prices,
        IAiReliabilityHistory reliability,
        IAiExecutionEvidenceStore evidence,
        IAiAuditEmitter audit)
    {
        ArgumentNullException.ThrowIfNull(usage);
        ArgumentNullException.ThrowIfNull(prices);
        ArgumentNullException.ThrowIfNull(reliability);
        ArgumentNullException.ThrowIfNull(evidence);
        ArgumentNullException.ThrowIfNull(audit);

        _usage = usage;
        _prices = prices;
        _reliability = reliability;
        _evidence = evidence;
        _audit = audit;
    }

    /// <summary>
    /// Records one provider invocation: its consumption, its cost and its outcome.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Called exactly once per provider call, after the call returns. It is never called before or from
    /// inside one, which is what keeps the reliability evidence a routing decision reads from containing
    /// that decision's own outcome.
    /// </para>
    /// <para>
    /// <b>It returns the entry it wrote.</b> An execution with a fallback makes more than one call and
    /// its authoritative cost is the sum of them, so a caller that had to re-read the ledger to total
    /// them would be reading back what it had just written — and on a concurrent estate it would
    /// sometimes total another execution's entry into this one's audit record.
    /// </para>
    /// </remarks>
    public AiUsageEntry RecordInvocation(AiInvocationFacts facts)
    {
        ArgumentNullException.ThrowIfNull(facts);

        var lookup = _prices.Lookup(facts.ModelId, facts.ProviderId, facts.Tier);

        // The measurement, not the prediction. Computed from the tokens the provider reported against
        // the configured rate, so it can disagree with the pre-invocation estimate and the disagreement
        // is the point.
        //
        // A measurement requires a MEASUREMENT. When the provider reported no usage there is nothing to
        // price, and the cost is unknown — not zero. Falling through with a fabricated zero here would
        // produce a real decimal from `CostOf(0, 0)`, and `BasisFor` would label it ActualRecorded:
        // a "measured" cost of nothing, which every budget ceiling passes. The null is deliberate and
        // is what keeps the unpriced and the unpaid-apart.
        var actual = facts.TokensIn is { } tokensIn && facts.TokensOut is { } tokensOut
            ? lookup.Quote?.CostOf(tokensIn, tokensOut)
            : null;
        var currency = lookup.Quote?.Currency ?? facts.Currency;
        var basis = AiCostReconciler.BasisFor(facts.PreInvocationEstimate, actual);

        var entry = new AiUsageEntry
        {
            ExecutionId = facts.ExecutionId,
            AttemptId = facts.AttemptId,
            RequestId = facts.RequestId,
            CorrelationId = facts.CorrelationId,
            Capability = facts.Capability,
            ModelId = facts.ModelId,
            ProviderId = facts.ProviderId,
            ProcessingTier = facts.Tier,
            IsFallback = facts.IsFallback,
            PrincipalId = facts.Requester.PrincipalId,
            ProductId = facts.Requester.ProductId,
            TenantId = facts.Requester.TenantId,
            WorkspaceId = facts.Requester.WorkspaceId,
            TokensIn = facts.TokensIn,
            TokensOut = facts.TokensOut,
            EstimatedCost = facts.PreInvocationEstimate,
            ActualCost = actual,
            Currency = currency,
            CostBasis = basis,
            PriceQuoteId = lookup.Quote?.QuoteId ?? facts.PriceQuoteId,
            RecordedAt = facts.At,
        };

        _usage.Record(entry);

        _reliability.Record(new AiReliabilityAttempt
        {
            ProviderId = facts.ProviderId,
            ModelId = facts.ModelId,
            Succeeded = facts.Succeeded,
            FailureCategory = facts.FailureCategory,
            Latency = facts.Latency,
            IsFallback = facts.IsFallback,
            At = facts.At,
        });

        return entry;
    }

    /// <summary>
    /// Writes the execution's routing evidence and its audit record, and returns the audit reference.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Two records, written together, for one execution. The order is evidence first and audit second,
    /// so that a reader who arrives between the two writes finds the execution's routing evidence
    /// without governance evidence rather than the reverse — the audit record is the one a reviewer
    /// resolves an execution reference against, and a record that appears before the evidence it joins
    /// to is a record that briefly disagrees with the estate.
    /// </para>
    /// <para>
    /// <b>W7F TASK 5: the priced-to-unpriced substitution is derived here, not recorded by the
    /// execution path.</b> The two facts it needs are already written — the primary route's projection
    /// and the serving route's absence of one — and a third write beside them would be a third record
    /// that must agree with the other two and no mechanism that makes it. Reading them here means the
    /// substitution cannot disagree with the failover record it is a statement about.
    /// </para>
    /// </remarks>
    public AiAuditRecord RecordExecution(AiExecutionFacts facts)
    {
        ArgumentNullException.ThrowIfNull(facts);

        var selected = facts.Routing?.Selected;

        _evidence.Write(new AiExecutionEvidence
        {
            ExecutionId = facts.ExecutionId,
            RequestId = facts.RequestId,
            Capability = facts.Capability,
            Tier = facts.Tier,
            EligibleRoutes = facts.Routing?.Eligible.Count ?? 0,
            RoutingRejections = facts.Routing?.Rejected ?? [],
            OperationalFindings = facts.Routing?.OperationalFindings ?? [],
            Budget = facts.Routing?.SelectedOperational?.Budget,
            BudgetSubstitution = AiBudgetSubstitution.Between(
                facts.Failover?.Primary,
                facts.Failover?.Selected),
            Reliability = facts.Routing?.SelectedOperational?.Reliability,
            Circuit = facts.Routing?.SelectedOperational?.Circuit,
            IsProbe = facts.Routing?.SelectedOperational?.IsProbe ?? false,
            ModelHealth = selected?.ModelHealth,
            ProviderHealth = selected?.ProviderHealth,
            Failover = facts.Failover,
            RecordedAt = facts.At,
        });

        return _audit.Emit(new AiAuditEmissionContext
        {
            ExecutionId = facts.ExecutionId,
            RequestId = facts.RequestId,
            CorrelationId = facts.CorrelationId,
            Requester = facts.Requester,
            Capability = facts.Capability,
            Purpose = facts.Purpose,
            Classification = facts.Classification,
            Timestamp = facts.At,
            ContextReferences = facts.ContextReferences,
            ProviderUsed = facts.ProviderUsed,
            ModelUsed = facts.ModelUsed,
            PromptVersion = facts.PromptVersion,
            ToolsInvoked = facts.ToolsInvoked,
            Usage = new AiTokenUsage
            {
                InputTokens = facts.TokensIn,
                OutputTokens = facts.TokensOut,
            },
            Cost = facts.Cost is { } amount && facts.Currency is { Length: > 0 } currency
                ? new AiCost
                {
                    Amount = amount,
                    Currency = currency,
                    IsEstimated = facts.CostBasis is not AiCostBasis.ActualRecorded,
                }
                : null,
            Timing = facts.Latency is { } latency ? new AiTiming { Total = latency } : null,
            PolicyDecision = new AiPolicyDecision
            {
                Allowed = facts.Decision.IsAllowed,
                RulesApplied = facts.Decision.RulesApplied,
                Reason = facts.Decision.Reason,

                // A pending human decision is not a decision a human has taken. Marking it decided would
                // make "waiting on a person" indistinguishable from "a person approved this".
                HumanDecided = false,
            },
            Status = facts.Status,
            FailureCategory = facts.FailureCategory,
            ResultHash = facts.ResultHash,
            ResultReference = facts.ResultReference,
        });
    }
}

/// <summary>
/// A digest of one context item, or nothing when the item is secret.
/// </summary>
/// <remarks>
/// <para>
/// The digest is what lets an auditor holding the original prove it was the content used, without the
/// record retaining a copy. It is withheld entirely for <see cref="DataClassification.Secret"/> items:
/// hashing a secret into a durable record extends its life rather than ending it, and a digest is only
/// non-reversible against an attacker who does not already hold candidates — the wrong assumption for a
/// value drawn from a small space.
/// </para>
/// <para>
/// <b>Digesting is not authorization.</b> The item reaching this method has already been admitted by the
/// exposure policy and, where required, redacted. This runs after that, over what was actually admitted,
/// so the record names what was sent rather than what the caller originally supplied.
/// </para>
/// </remarks>
public static class AiContextDigest
{
    /// <summary>The digest of a context item, or null when it must not be published.</summary>
    public static string? Of(ContextItem item)
    {
        ArgumentNullException.ThrowIfNull(item);

        if (item.Classification is DataClassification.Secret)
        {
            return null;
        }

        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(item.Body)));
    }

    /// <summary>The references for a set of admitted items, in order.</summary>
    public static IReadOnlyList<AiContextReference> RefsFor(IEnumerable<ContextItem> items)
    {
        ArgumentNullException.ThrowIfNull(items);

        return [.. items.Select(item => new AiContextReference
        {
            ContextItemId = item.Id,
            Classification = item.Classification ?? DataClassification.Public,
            ContentHash = Of(item),
        })];
    }
}
