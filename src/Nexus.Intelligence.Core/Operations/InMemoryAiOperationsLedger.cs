using System.Collections.Concurrent;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// The estate's operational ledger: one store, read two ways.
/// </summary>
/// <remarks>
/// <para>
/// <b>Usage and cost are the same entries.</b> They are facts about one execution, written at one
/// moment, from one routing decision. Two stores would be two things that must agree and no
/// mechanism that makes them, and the disagreement would appear as a usage figure and a cost figure
/// derived from different executions with nothing in either to say so.
/// </para>
/// <para>
/// <b>This is not a replacement for <c>IUsageMeter</c> and does not pretend to be one.</b> The
/// Platform meter records what the provider reported, against a record shape that carries no
/// capability, no execution and no provider. This records what the estate spent, against a shape
/// that carries all three, written once from the routing outcome where they were all known. The two
/// are joined by execution identity rather than merged, because merging them would require the
/// Platform contract plane to know about AI routing.
/// </para>
/// <para>
/// <b>In memory, and honest about it.</b> The committed estate has no durable store and this lane
/// does not add one. What it does add is a single write point and a read surface over it, so the
/// lane that adds persistence has one place to add it to rather than a scatter of call sites.
/// </para>
/// <para>
/// <b>Reads are ordered deterministically.</b> Entries are ordered by recording instant and then by
/// execution identifier, so two reads over the same contents produce byte-identical reports. Without
/// the tie-break, two executions recorded in the same tick would bucket in whatever order the
/// enumeration happened to produce, and a test asserting on a report would be asserting on a race.
/// </para>
/// </remarks>
public sealed class InMemoryAiOperationsLedger : IAiUsageLedger, IAiCostLedger
{
    private readonly ConcurrentQueue<AiUsageEntry> _entries = new();

    /// <summary>Every entry recorded, in recording order. An operational counter, not a read surface.</summary>
    public int Count => _entries.Count;

    /// <inheritdoc />
    public void Record(AiUsageEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        _entries.Enqueue(entry);
    }

    /// <inheritdoc />
    public AiUsageReport Query(AiUsageQuery query)
    {
        ArgumentNullException.ThrowIfNull(query);

        var matching = Matches(query).ToArray();

        var buckets = matching
            .GroupBy(entry => KeyFor(entry, query.GroupBy), StringComparer.Ordinal)
            .Select(group => new AiUsageAggregate
            {
                Key = group.Key,
                Executions = group.Count(),
                TokensIn = group.Sum(entry => entry.TokensIn),
                TokensOut = group.Sum(entry => entry.TokensOut),
                Cost = group.Sum(entry => entry.AuthoritativeCost ?? 0m),
                Currency = group
                    .Select(entry => entry.Currency)
                    .FirstOrDefault(currency => currency is not null),
                UnpricedExecutions = group.Count(entry => entry.AuthoritativeCost is null),
                FallbackExecutions = group.Count(entry => entry.IsFallback),
            })
            .OrderBy(bucket => bucket.Key, StringComparer.Ordinal)
            .ToArray();

        return new AiUsageReport
        {
            GroupBy = query.GroupBy,
            Buckets = buckets,
            Currencies = Currencies(buckets.Select(bucket => bucket.Currency)),
        };
    }

    /// <inheritdoc />
    public AiCostReport Query(AiCostQuery query)
    {
        ArgumentNullException.ThrowIfNull(query);

        var matching = CostEntries(query).ToArray();

        return new AiCostReport
        {
            Entries = matching.Length,
            TotalCost = matching.Sum(entry => entry.AuthoritativeAmount ?? 0m),
            TotalEstimated = matching.Sum(entry => entry.PreInvocationEstimate ?? 0m),
            TotalActual = matching.Sum(entry => entry.ActualRecorded ?? 0m),
            Currencies = Currencies(matching.Select(entry => entry.Currency)),
            UnpricedEntries = matching.Count(entry => entry.Basis is AiCostBasis.Unpriced),
            EstimatedOnlyEntries = matching.Count(entry => entry.Basis is AiCostBasis.Estimated),
            ActualRecordedEntries = matching.Count(entry => entry.Basis is AiCostBasis.ActualRecorded),
            Entries_ = matching,
        };
    }

    /// <inheritdoc />
    public AiBudgetSpend CommittedSpend(AiCostQuery query, string currency)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentException.ThrowIfNullOrWhiteSpace(currency);

        var matching = CostEntries(query).ToArray();

        return new AiBudgetSpend
        {
            Amount = matching
                .Where(entry => string.Equals(entry.Currency, currency, StringComparison.Ordinal))
                .Sum(entry => entry.AuthoritativeAmount ?? 0m),
            Currency = currency,
            Entries = matching.Count(entry => string.Equals(entry.Currency, currency, StringComparison.Ordinal)),
            ForeignCurrencyEntries = matching.Count(entry =>
                entry.Currency is not null && !string.Equals(entry.Currency, currency, StringComparison.Ordinal)),
            UnpricedEntries = matching.Count(entry => entry.AuthoritativeAmount is null),
        };
    }

    /// <summary>Every entry recorded so far, in recording order.</summary>
    public IReadOnlyList<AiUsageEntry> Entries() => [.. _entries];

    private IEnumerable<AiUsageEntry> Matches(AiUsageQuery query) => Ordered()
        .Where(entry => query.ExecutionId is null
            || string.Equals(entry.ExecutionId, query.ExecutionId, StringComparison.Ordinal))
        .Where(entry => query.RequestId is null
            || string.Equals(entry.RequestId, query.RequestId, StringComparison.Ordinal))
        .Where(entry => query.Capability is not { } capability || entry.Capability == capability)
        .Where(entry => query.ModelId is null
            || string.Equals(entry.ModelId, query.ModelId, StringComparison.Ordinal))
        .Where(entry => query.ProviderId is null
            || string.Equals(entry.ProviderId, query.ProviderId, StringComparison.Ordinal))
        .Where(entry => query.ProductId is null
            || string.Equals(entry.ProductId, query.ProductId, StringComparison.Ordinal))
        .Where(entry => query.TenantId is null
            || string.Equals(entry.TenantId, query.TenantId, StringComparison.Ordinal))
        .Where(entry => query.WorkspaceId is null
            || string.Equals(entry.WorkspaceId, query.WorkspaceId, StringComparison.Ordinal))
        .Where(entry => query.From is not { } from || entry.RecordedAt >= from)
        .Where(entry => query.To is not { } to || entry.RecordedAt < to);

    private IEnumerable<AiCostLedgerEntry> CostEntries(AiCostQuery query) => Ordered()
        .Where(entry => query.ExecutionId is null
            || string.Equals(entry.ExecutionId, query.ExecutionId, StringComparison.Ordinal))
        .Where(entry => query.Capability is not { } capability || entry.Capability == capability)
        .Where(entry => query.ModelId is null
            || string.Equals(entry.ModelId, query.ModelId, StringComparison.Ordinal))
        .Where(entry => query.ProviderId is null
            || string.Equals(entry.ProviderId, query.ProviderId, StringComparison.Ordinal))
        .Where(entry => query.ProductId is null
            || string.Equals(entry.ProductId, query.ProductId, StringComparison.Ordinal))
        .Where(entry => query.TenantId is null
            || string.Equals(entry.TenantId, query.TenantId, StringComparison.Ordinal))
        .Where(entry => query.WorkspaceId is null
            || string.Equals(entry.WorkspaceId, query.WorkspaceId, StringComparison.Ordinal))
        .Where(entry => query.From is not { } from || entry.RecordedAt >= from)
        .Where(entry => query.To is not { } to || entry.RecordedAt < to)
        .Where(entry => query.BasisIn.Count == 0 || query.BasisIn.Contains(entry.CostBasis))
        .Select(ToCostEntry);

    private IEnumerable<AiUsageEntry> Ordered() => _entries
        .OrderBy(entry => entry.RecordedAt)
        .ThenBy(entry => entry.ExecutionId, StringComparer.Ordinal);

    /// <summary>
    /// Projects one usage entry onto the cost read surface.
    /// </summary>
    /// <remarks>
    /// A projection and not a second record. Every figure here is computed from the entry's own
    /// members, so a cost report cannot disagree with the usage report it was drawn from — which is
    /// the whole reason the two surfaces share a store.
    /// </remarks>
    private static AiCostLedgerEntry ToCostEntry(AiUsageEntry entry) => new()
    {
        ExecutionId = entry.ExecutionId,
        RequestId = entry.RequestId,
        Capability = entry.Capability,
        ModelId = entry.ModelId,
        ProviderId = entry.ProviderId,
        Tier = entry.ProcessingTier,
        IsFallback = entry.IsFallback,
        ProductId = entry.ProductId,
        TenantId = entry.TenantId,
        WorkspaceId = entry.WorkspaceId,
        PreInvocationEstimate = entry.EstimatedCost,
        ActualRecorded = entry.ActualCost,
        Currency = entry.Currency,
        Basis = entry.CostBasis,
        EstimatedFromQuoteId = entry.CostBasis is AiCostBasis.Estimated ? entry.PriceQuoteId : null,
        ActualFromQuoteId = entry.CostBasis is AiCostBasis.ActualRecorded ? entry.PriceQuoteId : null,
        VarianceReason = AiCostReconciler.VarianceReason(entry.EstimatedCost, entry.ActualCost),
        RecordedAt = entry.RecordedAt,
    };

    private static string KeyFor(AiUsageEntry entry, AiUsageGroupBy groupBy) => groupBy switch
    {
        AiUsageGroupBy.Execution => entry.ExecutionId,
        AiUsageGroupBy.Capability => entry.Capability.Value,
        AiUsageGroupBy.Model => entry.ModelId,
        AiUsageGroupBy.Provider => entry.ProviderId,
        AiUsageGroupBy.Product => entry.ProductId ?? Unattributed,
        AiUsageGroupBy.Tenant => entry.TenantId ?? Unattributed,
        AiUsageGroupBy.Workspace => entry.WorkspaceId ?? Unattributed,
        AiUsageGroupBy.Principal => entry.PrincipalId ?? Unattributed,
        _ => Unattributed,
    };

    /// <summary>
    /// The bucket an unattributed entry falls in.
    /// </summary>
    /// <remarks>
    /// A named bucket rather than an empty key. An unset identifier and an identifier that happens to
    /// be the empty string are different facts, and collapsing them would make "we could not attribute
    /// this" look like "this belongs to the blank tenant".
    /// </remarks>
    public const string Unattributed = "(unattributed)";

    private static string[] Currencies(IEnumerable<string?> candidates) => [.. candidates
        .Where(currency => currency is not null)
        .Select(currency => currency!)
        .Distinct(StringComparer.Ordinal)
        .OrderBy(currency => currency, StringComparer.Ordinal)];
}
