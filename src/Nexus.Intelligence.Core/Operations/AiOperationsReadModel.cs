using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// Joins the audit trail, the ledgers and the execution evidence into one operator-facing read surface.
/// </summary>
/// <remarks>
/// <para>
/// <b>It keeps no history of its own.</b> Everything it answers is read from the three records the
/// governed path already writes: the audit record is what governance decided and how the execution
/// ended, the ledgers are what it consumed and cost, and the execution evidence is what the routing
/// and operational gates observed. A fourth store would be a fourth thing that must agree with the
/// other three and no mechanism that makes it, and it would disagree the first time one write path
/// failed.
/// </para>
/// <para>
/// <b>The audit record is the spine.</b> An execution with no audit record has no status, and a view
/// that invented one would hide exactly the gap an operator needs to see — an execution whose
/// governance evidence is missing. Such an execution's consumption is still readable through
/// <see cref="IAiUsageLedger"/>, which is where "how much" belongs; it simply has no operations view.
/// </para>
/// <para>
/// <b>An execution is attributed to the route that served it.</b> A fallback execution consumed tokens
/// on the failed primary attempt and on the alternate that succeeded, and both are spend. The view
/// sums the execution's consumption and attributes it to the serving route, with
/// <see cref="AiExecutionOperationsView.UsedFallback"/> marking it and
/// <see cref="AiOperationsBucket.FallbackExecutions"/> counting it in the rollup. Attributing per
/// attempt instead would give the bucket arithmetic a denominator no other field in it shares.
/// </para>
/// <para>
/// <b>Nothing here reaches a router, a registry or a provider.</b> Atlas and the Products consume this
/// through an adapter a later lane writes, and the whole point of reading records rather than live
/// objects is that the consumer cannot acquire a dependency on an implementation a lane then cannot
/// change.
/// </para>
/// </remarks>
public sealed class AiOperationsReadModel : IAiOperationsReadModel
{
    private readonly IAiAuditReader _audit;
    private readonly IAiUsageLedger _usage;
    private readonly IAiCostLedger _costs;
    private readonly IAiExecutionEvidenceStore _evidence;

    /// <summary>Builds the read model over the four records it joins.</summary>
    public AiOperationsReadModel(
        IAiAuditReader audit,
        IAiUsageLedger usage,
        IAiCostLedger costs,
        IAiExecutionEvidenceStore evidence)
    {
        ArgumentNullException.ThrowIfNull(audit);
        ArgumentNullException.ThrowIfNull(usage);
        ArgumentNullException.ThrowIfNull(costs);
        ArgumentNullException.ThrowIfNull(evidence);

        _audit = audit;
        _usage = usage;
        _costs = costs;
        _evidence = evidence;
    }

    /// <inheritdoc />
    public AiExecutionOperationsView? Execution(string executionId)
    {
        if (string.IsNullOrWhiteSpace(executionId))
        {
            return null;
        }

        var record = _audit.Find(executionId);

        return record is null ? null : Build(record, UsageTotals(), CostsByExecution());
    }

    /// <inheritdoc />
    public IReadOnlyList<AiExecutionOperationsView> Executions(AiOperationsQuery query)
    {
        ArgumentNullException.ThrowIfNull(query);

        var matched = Match(query);

        return query.Limit is { } limit ? [.. matched.Take(limit)] : matched;
    }

    /// <inheritdoc />
    public AiOperationsSummary Summarize(AiOperationsQuery query, AiUsageGroupBy groupBy)
    {
        ArgumentNullException.ThrowIfNull(query);

        var buckets = Match(query)
            .GroupBy(view => KeyFor(view, groupBy), StringComparer.Ordinal)
            .OrderBy(group => group.Key, StringComparer.Ordinal)
            .Select(group => Bucket(group.Key, group))
            .ToArray();

        return new AiOperationsSummary
        {
            GroupBy = groupBy,
            Buckets = query.Limit is { } limit ? [.. buckets.Take(limit)] : buckets,
        };
    }

    /// <summary>Every execution view matching a query, most recent first.</summary>
    /// <remarks>
    /// Ordered by the record's own timestamp and then by execution identifier, because two executions
    /// can carry the same instant and an ordering that left those ties to the storage layer would make
    /// two identical reads produce different sequences. The identifier is the tie-break rather than a
    /// write sequence because the sequence belongs to one store and this read joins three.
    /// </remarks>
    private IReadOnlyList<AiExecutionOperationsView> Match(AiOperationsQuery query)
    {
        var usage = UsageTotals();
        var costs = CostsByExecution();

        return [.. _audit
            .Recent(int.MaxValue)
            .Select(record => Build(record, usage, costs))
            .Where(view => Matches(view, query))
            .OrderByDescending(view => view.Timestamp)
            .ThenBy(view => view.ExecutionId, StringComparer.Ordinal)];
    }

    /// <summary>Builds one execution's view from its audit record and its totals.</summary>
    private AiExecutionOperationsView Build(
        AiAuditRecord record,
        IReadOnlyDictionary<string, (int Input, int Output)> usage,
        IReadOnlyDictionary<string, CostTotals> costs)
    {
        var evidence = _evidence.Find(record.ExecutionId);

        usage.TryGetValue(record.ExecutionId, out var tokens);
        costs.TryGetValue(record.ExecutionId, out var cost);

        var failover = evidence?.Failover;

        // The budget decision that governed this outcome, and which decision it is. W7F TASK 4: the
        // selection rule below is unchanged, and what is new is that the reading it produces is
        // published rather than left for a consumer to infer from the status.
        var (budget, budgetReading) = BudgetFor(record.Status, evidence);

        return new AiExecutionOperationsView
        {
            ExecutionId = record.ExecutionId,
            RequestId = record.RequestId,
            CorrelationId = record.CorrelationId,
            Capability = record.Capability,
            PrincipalId = record.Requester.PrincipalId,
            ProductId = record.Requester.ProductId,
            TenantId = record.Requester.TenantId,
            WorkspaceId = record.Requester.WorkspaceId,
            Status = record.Status,
            FailureCategory = record.FailureCategory,
            FailureCode = record.Status is AiExecutionStatus.Blocked ? record.PolicyDecision?.Reason : null,

            // The audit record is the authority on which route served the execution. The ledger is
            // consulted only where the audit record names none, which is the refused case where
            // nothing was served at all.
            ProviderId = record.ProviderUsed ?? cost.ProviderId,
            ModelId = record.ModelUsed ?? cost.ModelId,

            ModelHealth = evidence?.ModelHealth,
            ProviderHealth = evidence?.ProviderHealth,
            Circuit = evidence?.Circuit,
            IsProbe = evidence?.IsProbe ?? false,
            UsedFallback = failover?.UsedFallback ?? cost.AnyFallback,
            FailoverReasonCode = failover?.ReasonCode,
            FailoverAttempts = failover?.Attempts ?? [],

            EligibleRoutes = evidence?.EligibleRoutes ?? 0,
            RejectedRoutes = evidence?.RoutingRejections.Count ?? 0,
            RoutingRejections = evidence?.RoutingRejections ?? [],

            TokensIn = tokens.Input,
            TokensOut = tokens.Output,

            // Null rather than zero when nothing was priced: an execution with no price did not cost
            // nothing, and a zero would let it pass every ceiling the estate has.
            //
            // W7F TASK 5: the test is the BASIS, not the entry count, and the two are not the same
            // question. An execution the estate could not price still has ledger entries — the provider
            // call happened and its tokens were observed — so keying on the count published an amount of
            // zero for work whose cost nobody knows, which is the reading the directive forbids. An
            // execution that reached no provider has no entries and is null for the other reason, and
            // both are null here because neither has a figure.
            Cost = cost.EffectiveBasis is AiCostBasis.Unpriced ? null : cost.Amount,
            Currency = cost.Currency,
            CostBasis = cost.EffectiveBasis,
            Latency = record.Timing?.Total,

            GovernanceRules = record.PolicyDecision?.RulesApplied ?? [],
            GovernanceAllowed = record.PolicyDecision?.Allowed ?? false,

            // Written from one decision, so the three flat members cannot disagree with the whole.
            Budget = budget,
            BudgetReading = budgetReading,
            BudgetVerdict = budget?.Verdict,
            BudgetRuleId = budget?.RuleId,

            // TASK 5's substitution, carried through from the evidence rather than recomputed here. The
            // recorder derived it from the failover record at write time; re-deriving it at read time
            // would be a second implementation of one rule, and the two would disagree the first time
            // either changed.
            BudgetSubstitution = evidence?.BudgetSubstitution,

            Tier = evidence?.Tier ?? cost.Tier,
            Timestamp = record.Timestamp,
            AuditReference = record.ExecutionId,
        };
    }

    /// <summary>Whether a status is one under which no route was selected at all.</summary>
    /// <remarks>
    /// A refusal, in the estate's terms: policy stopped the execution before any candidate was chosen.
    /// <see cref="AiExecutionStatus.Failed"/> is deliberately NOT one, because a failure can be a route
    /// that was selected, attempted and did not work — and an execution that reached a provider is
    /// answering a different question from one that never did.
    /// </remarks>
    private static bool IsRefusal(AiExecutionStatus status)
        => status is AiExecutionStatus.Blocked or AiExecutionStatus.PendingHumanDecision;

    /// <summary>The budget decision that refused an execution, where one did.</summary>
    /// <remarks>
    /// The first refusing decision in candidate order, which is the router's own order — so two
    /// identical executions report the same rule. Taking the last, or whichever one a dictionary
    /// happened to enumerate first, would make the reported rule depend on the storage layer.
    /// </remarks>
    private static AiBudgetDecision? RefusedBudget(AiExecutionEvidence? evidence)
    {
        foreach (var finding in evidence?.OperationalFindings ?? [])
        {
            if (finding.Budget is { IsAllowed: false } decision)
            {
                return decision;
            }
        }

        return null;
    }

    /// <summary>
    /// The budget decision this execution's view reports, and which decision that is.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>W7F TASK 4: the rule is unchanged and is now named.</b> The evidence's own decision is the
    /// selected route's, so wherever it exists it is the answer and the reading says so. Where nothing
    /// was selected there is no selected candidate to read one from, and the decision that refused
    /// lives on the router's findings instead.
    /// </para>
    /// <para>
    /// <b>Read from the findings ONLY on a refusal, and the reading records that rather than leaving
    /// the status to imply it.</b> An execution that was served can still carry a finding about a
    /// <em>different</em> route the ceiling refused while another served, and reporting that route's
    /// ceiling as this execution's verdict would say a successful execution was blocked.
    /// </para>
    /// <para>
    /// <b>A selected-route decision outranks a refusal decision even when the execution was
    /// blocked.</b> The invocation gate can refuse a route the budget gate permitted, and there the
    /// evidence's decision is the honest answer about what the budget concluded — the execution was
    /// stopped by policy, not by cost, and a reading of <see cref="AiBudgetReading.Refusal"/> would
    /// attribute the outcome to the wrong gate. That is exactly the inference TASK 4 removes.
    /// </para>
    /// </remarks>
    private static (AiBudgetDecision? Decision, AiBudgetReading Reading) BudgetFor(
        AiExecutionStatus status,
        AiExecutionEvidence? evidence)
    {
        if (evidence?.Budget is { } selectedRoute)
        {
            return (selectedRoute, AiBudgetReading.SelectedRoute);
        }

        return IsRefusal(status) && RefusedBudget(evidence) is { } refused
            ? (refused, AiBudgetReading.Refusal)
            : (null, AiBudgetReading.None);
    }

    /// <summary>Whether a view satisfies every filter the query set.</summary>
    /// <remarks>
    /// An unset filter never narrows. The one place that matters is a null identity filter, which must
    /// not select the executions that have no such identity — that would turn an unset filter into the
    /// narrowest possible one and hide every attributed execution.
    /// </remarks>
    private static bool Matches(AiExecutionOperationsView view, AiOperationsQuery query)
    {
        if (query.ExecutionId is { } executionId
            && !string.Equals(view.ExecutionId, executionId, StringComparison.Ordinal))
        {
            return false;
        }

        if (query.RequestId is { } requestId
            && !string.Equals(view.RequestId, requestId, StringComparison.Ordinal))
        {
            return false;
        }

        if (query.Capability is { } capability && view.Capability != capability)
        {
            return false;
        }

        if (query.ProviderId is { } providerId
            && !string.Equals(view.ProviderId, providerId, StringComparison.Ordinal))
        {
            return false;
        }

        if (query.ModelId is { } modelId
            && !string.Equals(view.ModelId, modelId, StringComparison.Ordinal))
        {
            return false;
        }

        if (query.ProductId is { } productId
            && !string.Equals(view.ProductId, productId, StringComparison.Ordinal))
        {
            return false;
        }

        if (query.TenantId is { } tenantId
            && !string.Equals(view.TenantId, tenantId, StringComparison.Ordinal))
        {
            return false;
        }

        if (query.From is { } from && view.Timestamp < from)
        {
            return false;
        }

        if (query.To is { } to && view.Timestamp >= to)
        {
            return false;
        }

        if (query.StatusIn.Count > 0 && !query.StatusIn.Contains(view.Status))
        {
            return false;
        }

        if (query.FailureCategoryIn.Count > 0
            && (view.FailureCategory is not { } category || !query.FailureCategoryIn.Contains(category)))
        {
            return false;
        }

        if (query.UsedFallback is { } usedFallback && view.UsedFallback != usedFallback)
        {
            return false;
        }

        return true;
    }

    /// <summary>Rolls one group of views into a bucket.</summary>
    private static AiOperationsBucket Bucket(string key, IEnumerable<AiExecutionOperationsView> views)
    {
        var materialized = views as IReadOnlyList<AiExecutionOperationsView> ?? [.. views];

        var succeeded = materialized.Count(view => view.Status is
            AiExecutionStatus.Succeeded or AiExecutionStatus.PartiallySucceeded);

        // Degraded counts as a failure here rather than as a success, because it is the label that says
        // the deterministic path was taken instead. Folding it into the succeeded count would make a
        // week of degraded answers indistinguishable from a week of good ones on the graph an operator
        // actually looks at.
        var failed = materialized.Count(view => view.Status is
            AiExecutionStatus.Failed or AiExecutionStatus.Degraded);

        var blocked = materialized.Count(view => view.Status is
            AiExecutionStatus.Blocked or AiExecutionStatus.PendingHumanDecision);

        var latencies = materialized
            .Where(view => view.Latency is not null)
            .Select(view => view.Latency!.Value)
            .ToArray();

        var currencies = materialized
            .Where(view => view.Currency is not null)
            .Select(view => view.Currency!)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(currency => currency, StringComparer.Ordinal)
            .ToArray();

        var failures = new SortedDictionary<AiFailureCategory, int>();

        foreach (var category in materialized
            .Where(view => view.FailureCategory is not null)
            .Select(view => view.FailureCategory!.Value))
        {
            failures[category] = failures.TryGetValue(category, out var count) ? count + 1 : 1;
        }

        return new AiOperationsBucket
        {
            Key = key,
            Executions = materialized.Count,
            Succeeded = succeeded,
            Failed = failed,
            Blocked = blocked,
            FallbackExecutions = materialized.Count(view => view.UsedFallback),
            TotalTokens = materialized.Sum(view => view.TotalTokens),

            // TASK 5: the sum is over the executions that had a price, and the count beside it says how
            // many did not. Without the count this figure reads as the bucket's cost, and a bucket of
            // unpriceable work would read as a bucket that cost nothing.
            Cost = materialized.Sum(view => view.Cost ?? 0m),
            UnpricedExecutions = materialized.Count(view => view.CostBasis is AiCostBasis.Unpriced),
            Currency = currencies.Length == 1 ? currencies[0] : null,
            Currencies = currencies,
            AverageLatency = latencies.Length == 0
                ? null
                : TimeSpan.FromTicks((long)latencies.Average(latency => latency.Ticks)),
            FailuresByCategory = failures,
        };
    }

    /// <summary>The bucket an unattributed execution falls in.</summary>
    /// <remarks>
    /// The same marker the ledger uses, referenced rather than repeated: two spellings of "we could not
    /// attribute this" would put one execution in two buckets depending on which surface grouped it.
    /// </remarks>
    private const string Unattributed = InMemoryAiOperationsLedger.Unattributed;

    /// <summary>The grouping key for one execution.</summary>
    private static string KeyFor(AiExecutionOperationsView view, AiUsageGroupBy groupBy) => groupBy switch
    {
        AiUsageGroupBy.Execution => view.ExecutionId,
        AiUsageGroupBy.Capability => view.Capability.Value,
        AiUsageGroupBy.Model => view.ModelId ?? Unattributed,
        AiUsageGroupBy.Provider => view.ProviderId ?? Unattributed,
        AiUsageGroupBy.Product => view.ProductId ?? Unattributed,
        AiUsageGroupBy.Tenant => view.TenantId ?? Unattributed,
        AiUsageGroupBy.Workspace => view.WorkspaceId ?? Unattributed,
        AiUsageGroupBy.Principal => view.PrincipalId ?? Unattributed,
        _ => Unattributed,
    };

    /// <summary>Per-execution token totals, read once per query rather than once per execution.</summary>
    private IReadOnlyDictionary<string, (int Input, int Output)> UsageTotals()
    {
        var report = _usage.Query(new AiUsageQuery { GroupBy = AiUsageGroupBy.Execution });
        var totals = new Dictionary<string, (int, int)>(StringComparer.Ordinal);

        foreach (var bucket in report.Buckets)
        {
            totals[bucket.Key] = (bucket.TokensIn, bucket.TokensOut);
        }

        return totals;
    }

    /// <summary>Per-execution cost totals, read once per query rather than once per execution.</summary>
    private IReadOnlyDictionary<string, CostTotals> CostsByExecution()
    {
        var report = _costs.Query(new AiCostQuery());
        var totals = new Dictionary<string, CostTotals>(StringComparer.Ordinal);

        foreach (var entry in report.Entries_)
        {
            totals[entry.ExecutionId] = totals.TryGetValue(entry.ExecutionId, out var running)
                ? running.Add(entry)
                : CostTotals.First(entry);
        }

        return totals;
    }

    /// <summary>
    /// One execution's cost, accumulated over however many attempts it made.
    /// </summary>
    /// <remarks>
    /// The basis is decided by what the entries contain rather than by the last entry alone: a
    /// measurement anywhere in the execution makes the execution's figure measured, because a measured
    /// amount is what actually happened and a prediction beside it is a prediction. Unpriced only when
    /// nothing was priced at all — which is a different fact from a zero, and the reason the figure is
    /// null rather than zero in that case.
    /// </remarks>
    private readonly record struct CostTotals(
        decimal Amount,
        string? Currency,
        int Entries,
        int Priced,
        int Measured,
        bool AnyFallback,
        string? ProviderId,
        string? ModelId,
        AiProcessingTier Tier)
    {
        public static CostTotals First(AiCostLedgerEntry entry) => new(
            Amount: entry.AuthoritativeAmount ?? 0m,
            Currency: entry.Currency,
            Entries: 1,
            Priced: entry.Basis is AiCostBasis.Unpriced ? 0 : 1,
            Measured: entry.Basis is AiCostBasis.ActualRecorded ? 1 : 0,
            AnyFallback: entry.IsFallback,
            ProviderId: entry.ProviderId,
            ModelId: entry.ModelId,
            Tier: entry.Tier);

        public CostTotals Add(AiCostLedgerEntry entry) => this with
        {
            Amount = Amount + (entry.AuthoritativeAmount ?? 0m),

            // A single currency survives; a mix clears it. The reader is told through the currencies
            // the rollup carries rather than being handed a total that silently spans two of them.
            Currency = string.Equals(Currency, entry.Currency, StringComparison.Ordinal) ? Currency : null,
            Entries = Entries + 1,
            Priced = Priced + (entry.Basis is AiCostBasis.Unpriced ? 0 : 1),
            Measured = Measured + (entry.Basis is AiCostBasis.ActualRecorded ? 1 : 0),
            AnyFallback = AnyFallback || entry.IsFallback,
        };

        /// <summary>The basis a reader should assume for the accumulated amount.</summary>
        public AiCostBasis EffectiveBasis => Priced == 0
            ? AiCostBasis.Unpriced
            : Measured > 0 ? AiCostBasis.ActualRecorded : AiCostBasis.Estimated;
    }
}
