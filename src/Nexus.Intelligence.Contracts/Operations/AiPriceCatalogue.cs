namespace Nexus.Intelligence.Contracts;

/// <summary>
/// One price for one model, at one processing tier, in one currency.
/// </summary>
/// <remarks>
/// <para>
/// <b>A quote is a record, not a constant.</b> The directive forbids permanent hard-coded
/// provider/model prices in routing code, and the reason is not stylistic: a price compiled into an
/// assembly cannot be corrected by the person who owns the contract, and a wrong price does not
/// throw — it silently produces wrong budgets, wrong rankings and wrong invoices.
/// </para>
/// <para>
/// <see cref="QuoteId"/> exists so that a cost figure can name the price it was computed from. A
/// reconciled spend that cannot say which rate produced it is a number nobody can audit when the
/// rate turns out to have been wrong.
/// </para>
/// </remarks>
public sealed record AiPriceQuote
{
    /// <summary>A stable identifier for this quote. Recorded against every cost it produces.</summary>
    public required string QuoteId { get; init; }

    /// <summary>The model this price is for.</summary>
    public required string ModelId { get; init; }

    /// <summary>The provider this price is for.</summary>
    public required string ProviderId { get; init; }

    /// <summary>The processing tier this price applies to.</summary>
    public AiProcessingTier Tier { get; init; } = AiProcessingTier.Standard;

    /// <summary>Cost per 1,000 input tokens.</summary>
    public required decimal InputCostPer1kTokens { get; init; }

    /// <summary>Cost per 1,000 output tokens.</summary>
    public required decimal OutputCostPer1kTokens { get; init; }

    /// <summary>ISO 4217 currency of both rates.</summary>
    public required string Currency { get; init; }

    /// <summary>Where this price stands.</summary>
    public AiPricingStatus Status { get; init; } = AiPricingStatus.Current;

    /// <summary>The date the price took effect, where the source states one.</summary>
    public DateOnly? EffectiveFrom { get; init; }

    /// <summary>The date the price stops applying, where the source states one.</summary>
    public DateOnly? EffectiveTo { get; init; }

    /// <summary>Where the price came from, for review. Never a credential or an authenticated URL.</summary>
    public string? Source { get; init; }

    /// <summary>
    /// True when this quote may be used to compute a cost for a new execution.
    /// </summary>
    /// <remarks>
    /// <see cref="AiPricingStatus.Expired"/> is not usable and <see cref="AiPricingStatus.NeedsReview"/>
    /// is: an expired price is no longer the price, whereas a price flagged for review is still the
    /// best statement available and refusing it would make the estate unable to price anything the
    /// day someone flags a rate for checking.
    /// </remarks>
    public bool IsUsable => Status is AiPricingStatus.Current
        or AiPricingStatus.NeedsReview
        or AiPricingStatus.ManualOverride;

    /// <summary>
    /// The cost of a given token count under this quote, or null when this quote may not be used.
    /// </summary>
    public decimal? CostOf(int inputTokens, int outputTokens)
        => IsUsable
            ? (inputTokens / 1000m * InputCostPer1kTokens) + (outputTokens / 1000m * OutputCostPer1kTokens)
            : null;
}

/// <summary>
/// The result of asking the catalogue for a price, including the two ways it can decline.
/// </summary>
public sealed record AiPriceLookup
{
    /// <summary>What the lookup concluded.</summary>
    public required AiPricingLookupState State { get; init; }

    /// <summary>The quote, present exactly when <see cref="State"/> is <see cref="AiPricingLookupState.Found"/>.</summary>
    public AiPriceQuote? Quote { get; init; }

    /// <summary>A caller-safe explanation of a non-found state.</summary>
    public string? Detail { get; init; }

    /// <summary>True when a usable quote was found.</summary>
    public bool IsFound => State is AiPricingLookupState.Found && Quote is not null;

    /// <summary>A miss, with the reason and the candidates that made it a miss where there were some.</summary>
    public static AiPriceLookup Miss(AiPricingLookupState state, string detail) => new()
    {
        State = state,
        Detail = detail,
    };

    /// <summary>A hit.</summary>
    public static AiPriceLookup Hit(AiPriceQuote quote) => new()
    {
        State = AiPricingLookupState.Found,
        Quote = quote,
    };
}

/// <summary>
/// The authority for what a model costs.
/// </summary>
/// <remarks>
/// <para>
/// <b>Synchronous and side-effect free, because it is consulted inside routing.</b> A price lookup
/// that reached a network would put I/O inside a decision that must be reproducible from its inputs,
/// and would make a budget verdict depend on the weather.
/// </para>
/// <para>
/// <b>It reads registry metadata rather than owning a table.</b> The estate already declares input
/// and output rates on each model registration; a second price table would be a second answer to
/// "what does this cost", and the two would disagree the first time someone updated one of them.
/// </para>
/// </remarks>
public interface IAiPriceCatalogue
{
    /// <summary>Finds the price for a model on a provider at a processing tier.</summary>
    AiPriceLookup Lookup(string modelId, string providerId, AiProcessingTier tier);
}

/// <summary>
/// One execution's cost, with the prediction, the measurement, and the reconciliation between them.
/// </summary>
/// <remarks>
/// <para>
/// <b>The reconciliation is the deliverable, not the number.</b> Storing only a final figure would
/// answer "what did it cost" and leave "was the prediction any good" unanswerable — and that second
/// question is the one that decides whether the estate's pricing metadata can be trusted to gate
/// spend.
/// </para>
/// <para>
/// <see cref="VarianceReason"/> is required whenever the two figures disagree materially, because a
/// divergence with no recorded explanation is a divergence someone will re-investigate from
/// scratch.
/// </para>
/// </remarks>
public sealed record AiCostLedgerEntry
{
    /// <summary>The execution this cost belongs to. The join key to usage and audit.</summary>
    public required string ExecutionId { get; init; }

    /// <summary>The caller's request identifier.</summary>
    public required string RequestId { get; init; }

    /// <summary>The capability served.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>The model that served it.</summary>
    public required string ModelId { get; init; }

    /// <summary>The provider that served it.</summary>
    public required string ProviderId { get; init; }

    /// <summary>The processing tier the price was resolved at.</summary>
    public AiProcessingTier Tier { get; init; } = AiProcessingTier.Standard;

    /// <summary>True when this entry belongs to a fallback attempt.</summary>
    public bool IsFallback { get; init; }

    /// <summary>The product the spend is attributed to, where the caller named one.</summary>
    public string? ProductId { get; init; }

    /// <summary>The tenant the spend is attributed to, where the caller named one.</summary>
    public string? TenantId { get; init; }

    /// <summary>The workspace the spend is attributed to, where the caller named one.</summary>
    public string? WorkspaceId { get; init; }

    /// <summary>The prediction made before the provider call, where a price was available.</summary>
    public decimal? PreInvocationEstimate { get; init; }

    /// <summary>The figure computed from the tokens the provider actually reported.</summary>
    public decimal? ActualRecorded { get; init; }

    /// <summary>The currency both figures are in, or null when neither exists.</summary>
    public string? Currency { get; init; }

    /// <summary>Which figure is authoritative for this execution.</summary>
    public required AiCostBasis Basis { get; init; }

    /// <summary>The quote the prediction used, so the rate behind a budget decision is recoverable.</summary>
    public string? EstimatedFromQuoteId { get; init; }

    /// <summary>The quote the measurement used.</summary>
    public string? ActualFromQuoteId { get; init; }

    /// <summary>Why the prediction and the measurement differ, when they do.</summary>
    public string? VarianceReason { get; init; }

    /// <summary>When the cost was recorded.</summary>
    public required DateTimeOffset RecordedAt { get; init; }

    /// <summary>The figure a reader should use.</summary>
    public decimal? AuthoritativeAmount => Basis switch
    {
        AiCostBasis.ActualRecorded => ActualRecorded,
        AiCostBasis.Estimated => PreInvocationEstimate,
        _ => null,
    };
}

/// <summary>Which cost entries a read is asking for.</summary>
public sealed record AiCostQuery
{
    /// <summary>Restrict to one execution.</summary>
    public string? ExecutionId { get; init; }

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

    /// <summary>Restrict to entries whose basis is one of these. Empty means no restriction.</summary>
    public IReadOnlyList<AiCostBasis> BasisIn { get; init; } = [];
}

/// <summary>
/// The reconciliation of predicted and measured cost across a set of executions.
/// </summary>
/// <remarks>
/// Reported as a pair of totals plus the residual count rather than as an accuracy percentage. A
/// percentage over a set that includes unpriced executions is a statistic about the priced subset
/// presented as though it were about the whole, and the whole is what a budget owner is deciding
/// about.
/// </remarks>
public sealed record AiCostReport
{
    /// <summary>How many entries matched.</summary>
    public required int Entries { get; init; }

    /// <summary>Sum of the authoritative amounts.</summary>
    public required decimal TotalCost { get; init; }

    /// <summary>Sum of the pre-invocation predictions across entries that had one.</summary>
    public required decimal TotalEstimated { get; init; }

    /// <summary>Sum of the recorded measurements across entries that had one.</summary>
    public required decimal TotalActual { get; init; }

    /// <summary>The distinct currencies present.</summary>
    public IReadOnlyList<string> Currencies { get; init; } = [];

    /// <summary>How many entries had no price at all.</summary>
    public int UnpricedEntries { get; init; }

    /// <summary>How many entries were priced only from a prediction.</summary>
    public int EstimatedOnlyEntries { get; init; }

    /// <summary>How many entries were measured.</summary>
    public int ActualRecordedEntries { get; init; }

    /// <summary>The per-entry reconciliations, in execution-identifier order.</summary>
    public IReadOnlyList<AiCostLedgerEntry> Entries_ { get; init; } = [];

    /// <summary>True when the report covers a single currency and its totals are meaningful.</summary>
    public bool IsSingleCurrency => Currencies.Count <= 1;
}

/// <summary>
/// The authoritative AI cost ledger: one read surface over the same entries usage is read from.
/// </summary>
/// <remarks>
/// <para>
/// <b>One store, two read surfaces.</b> Usage and cost are recorded on one entry because they are
/// facts about one execution; splitting them into two stores would create two places that must
/// agree and no mechanism that makes them. The read surfaces differ in emphasis — usage answers
/// "how much", cost answers "at what rate, predicted how well" — not in source.
/// </para>
/// <para>
/// <b>This is where a period budget gets its committed spend.</b> A daily ceiling is a comparison
/// against what has already been spent today, and this ledger is the only thing that knows.
/// </para>
/// </remarks>
public interface IAiCostLedger
{
    /// <summary>Reads cost back, filtered. Never null; an empty report is a result.</summary>
    AiCostReport Query(AiCostQuery query);

    /// <summary>
    /// The committed spend over a window, in one currency, for the executions a filter selects.
    /// </summary>
    /// <remarks>
    /// The currency is a parameter rather than derived, because a window containing two currencies
    /// has no spend total. Entries in another currency contribute nothing and are counted in
    /// <see cref="AiBudgetSpend.ForeignCurrencyEntries"/> so the omission is visible.
    /// </remarks>
    AiBudgetSpend CommittedSpend(AiCostQuery query, string currency);
}

/// <summary>The spend already committed over a budget window.</summary>
public sealed record AiBudgetSpend
{
    /// <summary>The amount committed, in <see cref="Currency"/>.</summary>
    public required decimal Amount { get; init; }

    /// <summary>The currency the amount is in.</summary>
    public required string Currency { get; init; }

    /// <summary>How many entries contributed.</summary>
    public required int Entries { get; init; }

    /// <summary>How many matching entries were in a different currency and contributed nothing.</summary>
    public int ForeignCurrencyEntries { get; init; }

    /// <summary>How many matching entries had no price and contributed nothing.</summary>
    public int UnpricedEntries { get; init; }

    /// <summary>Nothing committed.</summary>
    public static AiBudgetSpend Zero(string currency) => new()
    {
        Amount = 0m,
        Currency = currency,
        Entries = 0,
    };
}
