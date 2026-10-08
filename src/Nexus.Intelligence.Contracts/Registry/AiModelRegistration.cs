namespace Nexus.Intelligence.Contracts;

/// <summary>
/// One model, as the registry states it: what it can do, what it costs, and whether it is on offer.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is a registry entry, not a routing decision and not a governance approval.</b> It says a
/// model exists and what it is; the router decides whether it is the right one for a piece of work,
/// and <see cref="IAiGovernanceRegister"/> decides whether the choice may proceed. The three are
/// deliberately separate: a registry that also ranked would have to know the caller's policy, and a
/// registry that also approved would make an operator's inventory edit into a permission grant.
/// </para>
/// <para>
/// <b>Every governance-shaped field here is a declaration the register projects from, not a second
/// source of truth.</b> <see cref="Approval"/>, <see cref="MaxClassification"/> and
/// <see cref="GovernanceRationale"/> exist so that the record an operator writes is one record, and
/// the <see cref="IAiGovernanceRegister"/> implementation supplied by W7C is a view over it. If they
/// were instead duplicated into a separate approval store there would be two records that can
/// disagree, and the disagreement would surface as a model that routes and is refused.
/// </para>
/// <para>
/// <b>The defaults all refuse.</b> <see cref="Enabled"/> is false, <see cref="Availability"/> is
/// <see cref="AiModelAvailability.Unknown"/>, <see cref="Approval"/> is
/// <see cref="AiGovernanceApprovalStatus.Unregistered"/>, and <see cref="MaxClassification"/> is
/// <see cref="DataClassification.Public"/>. A configuration entry that declares a model and nothing
/// else therefore produces a model that cannot be routed to and cannot be approved — which is the
/// correct reading of an entry that has not said what it is for.
/// </para>
/// </remarks>
public sealed record AiModelRegistration
{
    /// <summary>
    /// The model identifier, in the estate's vendor-prefixed form (<c>openai:gpt-4.1</c>).
    /// </summary>
    /// <remarks>
    /// Kept as the registry's identity because it is already the identity everywhere else — on
    /// <c>ModelInvocation.ModelId</c>, on <see cref="AiRoleAssignment"/>, and on
    /// <see cref="AiModelGovernanceRecord"/>. A new identity type here would be a second identity
    /// system for one concept, and the governance register would key on a different string than the
    /// router selected with.
    /// </remarks>
    public required string ModelId { get; init; }

    /// <summary>The provider that serves it, as the registry states it. Half of the governance key.</summary>
    public required string ProviderId { get; init; }

    /// <summary>A human-readable name, for reports. Never used to decide anything.</summary>
    public required string DisplayName { get; init; }

    /// <summary>
    /// The semantic capabilities this model serves, e.g. <see cref="AiCapabilities.CodeReview"/>.
    /// </summary>
    /// <remarks>
    /// The link between what a caller asks for and what can answer. Empty means the model serves no
    /// capability and is therefore unreachable by routing — which is why it is not defaulted to
    /// "everything": a capability granted by omission is the failure this list exists to prevent.
    /// </remarks>
    public IReadOnlyList<CapabilityId> Capabilities { get; init; } = [];

    /// <summary>Tokens the model accepts in one call, where the vendor states it. Null means unstated.</summary>
    public int? MaxContextTokens { get; init; }

    /// <summary>Tokens the model will emit in one call, where the vendor states it. Null means unstated.</summary>
    public int? MaxOutputTokens { get; init; }

    /// <summary>What the model accepts. Nothing is inferred; an undeclared modality cannot be sent.</summary>
    public IReadOnlyList<AiModelModality> InputModalities { get; init; } = [AiModelModality.Text];

    /// <summary>What the model returns.</summary>
    public IReadOnlyList<AiModelModality> OutputModalities { get; init; } = [AiModelModality.Text];

    /// <summary>The deepest reasoning class the model supports.</summary>
    public AiReasoningClass Reasoning { get; init; } = AiReasoningClass.None;

    /// <summary>How quickly the model is expected to answer, as a class. Feeds ranking, not a ceiling.</summary>
    /// <remarks>
    /// Stated by an operator and treated as an expectation rather than a measurement. See
    /// <see cref="AiRelativeSpeed"/> for why the estate records a class instead of a duration, and for
    /// why enforcing a caller's latency budget is a different lane's work.
    /// </remarks>
    public AiRelativeSpeed RelativeSpeed { get; init; } = AiRelativeSpeed.Unknown;

    /// <summary>Whether the model is on offer, on lifecycle grounds.</summary>
    public AiModelAvailability Availability { get; init; } = AiModelAvailability.Unknown;

    /// <summary>Whether an operator has switched the model on for routing.</summary>
    public bool Enabled { get; init; }

    /// <summary>
    /// Where this model's pricing is recorded, e.g. <c>pricing://openai/gpt-4.1</c>.
    /// </summary>
    /// <remarks>
    /// A reference and not the authority: the rates below are what the estimator uses, and this field
    /// is what makes them reviewable against the source they were transcribed from. A cost that
    /// cannot be traced to a published rate is a cost nobody can check.
    /// </remarks>
    public string? CostMetadataReference { get; init; }

    /// <summary>Cost per thousand input tokens in <see cref="CostCurrency"/>, where known.</summary>
    public decimal? InputCostPer1kTokens { get; init; }

    /// <summary>Cost per thousand output tokens in <see cref="CostCurrency"/>, where known.</summary>
    public decimal? OutputCostPer1kTokens { get; init; }

    /// <summary>ISO 4217 code for the two rates. Null when no rate is stated.</summary>
    public string? CostCurrency { get; init; }

    /// <summary>
    /// Where the stated rates stand, as an operator has recorded them.
    /// </summary>
    /// <remarks>
    /// <see cref="AiPricingStatus.Expired"/> is the member that matters: an expired rate is
    /// <b>recorded but not used</b>, so the estate refuses rather than pricing an execution from a
    /// number it knows is wrong. It is a distinct state from "no rate stated", because the two have
    /// different remedies — one needs a new price, the other needs someone to look at why the old one
    /// lapsed.
    /// </remarks>
    public AiPricingStatus PriceStatus { get; init; } = AiPricingStatus.Current;

    /// <summary>The date the stated rates took effect, where the source states one.</summary>
    public DateOnly? PriceEffectiveFrom { get; init; }

    /// <summary>The date the stated rates stopped applying, where the source states one.</summary>
    public DateOnly? PriceEffectiveTo { get; init; }

    /// <summary>
    /// The processing tiers this model supports. Defaults to standard interactive processing only.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Declared metadata, and the only source the processing-tier gate reads.</b> W7E resolves
    /// <c>PROCESSING_TIER_UNSUPPORTED</c> from this member and from nothing else — not from a model
    /// identifier, not from a provider name, and not from the presence of a tier-specific price. A
    /// gate that inferred support from a name would classify the next model by resemblance to the
    /// last one, and the mis-classification would be silent because the gate would still return a
    /// definite answer.
    /// </para>
    /// <para>
    /// The default is the narrow one. A model whose configuration says nothing about tiers supports
    /// exactly the interactive case every model supports, so a request for batch or priority
    /// processing against an unconfigured entry is refused rather than assumed. An operator who
    /// configures a tier has made a claim; an operator who configures nothing has not.
    /// </para>
    /// </remarks>
    public IReadOnlyList<AiProcessingTier> ProcessingTiers { get; init; } = [AiProcessingTier.Standard];

    /// <summary>Whether the model declares support for a processing tier.</summary>
    public bool SupportsTier(AiProcessingTier tier) => ProcessingTiers.Contains(tier);

    /// <summary>Whether the model has been approved for use by AI Governance.</summary>
    public AiGovernanceApprovalStatus Approval { get; init; } = AiGovernanceApprovalStatus.Unregistered;

    /// <summary>The most sensitive classification this model is cleared to receive.</summary>
    public DataClassification MaxClassification { get; init; } = DataClassification.Public;

    /// <summary>Who approved it. Required for an approval to be reviewable.</summary>
    public string? ApprovedBy { get; init; }

    /// <summary>Why it is in the state it is in. Required, so no entry arrives without a reason.</summary>
    public required string GovernanceRationale { get; init; }

    /// <summary>True when this model claims to serve the capability.</summary>
    public bool Declares(CapabilityId capability)
    {
        ArgumentNullException.ThrowIfNull(capability);

        return Capabilities.Contains(capability);
    }

    /// <summary>
    /// What the model is predicted to cost for the given token counts, or null when it cannot be said.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Null is a meaningful answer and not a zero. A model whose rates are unstated does not cost
    /// nothing; the cost is unknown, and the governance engine refuses a priced execution whose cost
    /// it cannot compute (<see cref="AiGovernanceRules.BudgetUncovered"/>). Returning zero here would
    /// hand every budget ceiling a number that always passes.
    /// </para>
    /// <para>
    /// One rate unstated makes the whole estimate unknown rather than half-known: pricing input while
    /// guessing output produces a number that is wrong by an unknown amount and looks precise.
    /// </para>
    /// <para>
    /// <b>A rate marked <see cref="AiPricingStatus.Expired"/> is treated exactly as an unstated one.</b>
    /// The estate recorded the rate and has stopped standing behind it, so the honest answer is that
    /// the cost is unknown — not the old number. Returning the stale figure would let an expired rate
    /// gate a budget decision while every part of the configuration said it should not, and the
    /// divergence would be invisible because the number would still look plausible.
    /// </para>
    /// </remarks>
    public decimal? EstimateCost(int inputTokens, int outputTokens)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(inputTokens);
        ArgumentOutOfRangeException.ThrowIfNegative(outputTokens);

        if (PriceStatus is AiPricingStatus.Expired)
        {
            return null;
        }

        if (InputCostPer1kTokens is not { } inputRate || OutputCostPer1kTokens is not { } outputRate)
        {
            return null;
        }

        return ((inputTokens / 1000m) * inputRate) + ((outputTokens / 1000m) * outputRate);
    }
}
