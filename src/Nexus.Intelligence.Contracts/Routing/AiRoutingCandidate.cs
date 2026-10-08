namespace Nexus.Intelligence.Contracts;

/// <summary>
/// What the router knows about the work before it has chosen a route.
/// </summary>
/// <remarks>
/// <para>
/// <b>None of this is caller-facing, and none of it can name a provider or a model.</b> Every member
/// is a fact about the <em>work</em> — how big it is, what shape it is, how sensitive it is. The
/// distinction is the whole boundary: a caller may say "this input is 40,000 tokens", and may not say
/// "use OpenAI". This type is how the first is expressible without the second becoming expressible.
/// </para>
/// <para>
/// <b>The defaults state nothing, and stating nothing is not a claim.</b> Zero tokens means the caller
/// did not size the work, not that it is empty; a null product means unscoped, not exempt. Each gate
/// below therefore has to decide what an unstated value means, and each one refuses only when it has
/// something to refuse — a caller who said nothing about size is not refused for exceeding a limit
/// nobody named.
/// </para>
/// </remarks>
public sealed record AiRoutingContext
{
    /// <summary>How many tokens the request is expected to send. Zero means the caller did not estimate.</summary>
    public int InputTokens { get; init; }

    /// <summary>How many tokens the caller expects back. Zero means the caller did not estimate.</summary>
    public int OutputTokens { get; init; }

    /// <summary>
    /// The modality of the input. Defaults to text, because a request that says nothing is text.
    /// </summary>
    public AiModelModality InputModality { get; init; } = AiModelModality.Text;

    /// <summary>
    /// The modality the caller requires back. Defaults to text.
    /// </summary>
    public AiModelModality OutputModality { get; init; } = AiModelModality.Text;

    /// <summary>
    /// The least reasoning class the work needs. <see cref="AiReasoningClass.None"/> means no requirement.
    /// </summary>
    /// <remarks>
    /// Set by the AI Head when it dispatches a capability, from what that capability needs — not by the
    /// caller, who has no way to express it and should not. It lives here rather than on the
    /// capability register so that the requirement travels with the request that has it, and so the
    /// registry stays a statement of what models <em>are</em>.
    /// </remarks>
    public AiReasoningClass RequiredReasoning { get; init; } = AiReasoningClass.None;

    /// <summary>
    /// The processing tier the work is to run under. Set by the AI Head when it dispatches, like
    /// <see cref="RequiredReasoning"/> and for the same reason.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A tier is a statement about how work may be processed — at interactive speed, deferred, at a
    /// discount, or expedited — and the model's declared
    /// <see cref="AiModelRegistration.ProcessingTiers"/> is the only thing that says whether it can be.
    /// W7E's operational gate reads both and refuses a mismatch as
    /// <see cref="AiRoutingRejectionReason.ProcessingTierUnsupported"/>.
    /// </para>
    /// <para>
    /// The default is <see cref="AiProcessingTier.Standard"/> because that is what an unstated request
    /// is: work that expects an answer at interactive speed, with no deferral and no expedite. A caller
    /// that wants batch pricing has to say so. The direction matters — the opposite default would
    /// quietly defer work nobody agreed to defer, and the deferral would look like latency rather than
    /// like a decision.
    /// </para>
    /// </remarks>
    public AiProcessingTier ProcessingTier { get; init; } = AiProcessingTier.Standard;

    /// <summary>
    /// The classifications of the context supplied, where the dispatcher knows them.
    /// </summary>
    /// <remarks>
    /// <b>Empty means not stated, and W7C cannot derive it.</b> A <see cref="ContextItem"/> carries a
    /// <see cref="TrustLevel"/> and no classification, so the router has nothing to read and will not
    /// invent a value: guessing that an item is <see cref="DataClassification.Internal"/> because it
    /// came from an internal caller would be exactly the silent downgrade the exposure policy exists
    /// to prevent. The seam is therefore explicit, and the lane that owns context wiring —
    /// <see cref="AiGovernanceSubject.ContextPermission"/>'s — fills it.
    /// </remarks>
    public IReadOnlyList<DataClassification> ContextClassifications { get; init; } = [];

    /// <summary>
    /// The tool identifiers the execution intends to invoke.
    /// </summary>
    /// <remarks>
    /// <b>Empty means the work intends to call no tools, not that nobody asked.</b>
    /// <see cref="AiCapabilityRequest.Tools"/> states what the caller <em>permits</em> — a ceiling and
    /// an allow-list — and this states what the execution will actually attempt. Both are needed and
    /// they are different questions: a profile permitting ten tools does not mean ten will be called,
    /// and the governance engine checks the named ones against the profile. Leaving this empty while
    /// the work does call tools would route an execution whose tool permissions were never evaluated.
    /// </remarks>
    public IReadOnlyList<string> RequestedToolIds { get; init; } = [];

    /// <summary>States nothing about the work. The most permissive context, and it claims nothing.</summary>
    public static AiRoutingContext Unstated { get; } = new();
}

/// <summary>
/// One route the router considered and did not select, with the reason and the values behind it.
/// </summary>
/// <remarks>
/// <para>
/// <b>Rejections are reported, not discarded.</b> A routing decision that returned only its winner
/// would be unreviewable: the question an operator actually asks is not "what did it pick" but "why
/// did it not pick the one I expected", and that question is answerable only from the rejects.
/// </para>
/// <para>
/// <see cref="Governance"/> is populated exactly when governance was the reason, so a refusal that
/// came from policy carries the rule that produced it rather than a restatement of it in the router's
/// own words — two accounts of one refusal is how a record starts disagreeing with itself.
/// </para>
/// </remarks>
public sealed record AiRoutingRejection
{
    /// <summary>The model that was considered.</summary>
    public required string ModelId { get; init; }

    /// <summary>The provider the model named, whether or not it resolved.</summary>
    public required string ProviderId { get; init; }

    /// <summary>Which gate refused it.</summary>
    public required AiRoutingRejectionReason Reason { get; init; }

    /// <summary>The values behind the refusal — which limit, by how much.</summary>
    public required string Detail { get; init; }

    /// <summary>The governance decision, when governance was the gate that fired.</summary>
    public AiGovernanceDecision? Governance { get; init; }
}

/// <summary>
/// A route that survived every gate, with the evidence that got it through.
/// </summary>
/// <remarks>
/// <para>
/// <b>A candidate is a permitted route, never a merely plausible one.</b> By the time one of these is
/// constructed, the model and provider are registered, enabled, routable on lifecycle and health, able
/// to serve the capability, inside the caller's cost ceiling, and approved by AI Governance for this
/// exact request. Nothing downstream re-checks any of that, which is why nothing downstream may accept
/// a candidate from any other source.
/// </para>
/// <para>
/// <see cref="Destination"/> is derived from the provider's egress permission rather than from the
/// request, and that is deliberate: it is what makes the exposure policy evaluate each candidate
/// against the place the content would <em>actually</em> go. A request that carried one destination
/// for the whole routing would evaluate a remote fallback as though it were local, and the exposure
/// table would answer a question nobody asked.
/// </para>
/// </remarks>
public sealed record AiRoutingCandidate
{
    /// <summary>The model, as registered.</summary>
    public required AiModelRegistration Model { get; init; }

    /// <summary>The provider, as registered.</summary>
    public required AiProviderRegistration Provider { get; init; }

    /// <summary>Where this route would send content, derived from the provider's egress permission.</summary>
    public required AiDestinationClass Destination { get; init; }

    /// <summary>How the health source reports the model.</summary>
    public required AiModelHealthState ModelHealth { get; init; }

    /// <summary>How the health source reports the provider.</summary>
    /// <remarks>
    /// The same vocabulary as <see cref="ModelHealth"/>, because a provider and a model become
    /// unroutable in the same ways. Two enums would invite a mapping between them, and the mapping
    /// would be where a state that is unroutable for a model quietly becomes routable for a provider.
    /// </remarks>
    public required AiModelHealthState ProviderHealth { get; init; }

    /// <summary>The predicted cost, or null when the route's rates do not allow a prediction.</summary>
    public decimal? EstimatedCost { get; init; }

    /// <summary>The currency <see cref="EstimatedCost"/> is in, or null when there is no estimate.</summary>
    public string? CostCurrency { get; init; }

    /// <summary>What governance decided about this route for this request.</summary>
    public required AiGovernanceDecision Governance { get; init; }

    /// <summary>The ranking score, higher being better.</summary>
    public decimal Score { get; init; }

    /// <summary>
    /// The named components that produced <see cref="Score"/>, for review.
    /// </summary>
    /// <remarks>
    /// A trace rather than a number, for the reason <see cref="AiGovernanceDecision.RulesApplied"/>
    /// is one: a ranking nobody can decompose is a ranking nobody can defend, and "why is this route
    /// preferred" is answered by reading the components rather than by re-deriving the arithmetic.
    /// </remarks>
    public IReadOnlyList<string> ScoreComponents { get; init; } = [];

    /// <summary>The model's identifier. Reaches the governance request, so it is stated once.</summary>
    public string ModelId => Model.ModelId;

    /// <summary>The provider's identifier.</summary>
    public string ProviderId => Provider.ProviderId;
}
