namespace Nexus.Intelligence.Contracts;

/// <summary>
/// What the router concluded about one capability request, with the evidence behind it.
/// </summary>
/// <remarks>
/// <para>
/// <b>The evidence is the deliverable as much as the selection is.</b> Everything the router looked at
/// is on this record: every route it permitted, every route it refused and why, and the governance
/// decision that governs the outcome. A caller receives a selected route; an operator receives the
/// reason it was selected and the reasons the others were not, from the same object, without a second
/// query against a store that might have moved on.
/// </para>
/// <para>
/// <b><see cref="Eligible"/> and <see cref="FallbackChain"/> are both post-governance, and that is the
/// structural guarantee that a fallback cannot bypass policy.</b> A failover walks
/// <see cref="FallbackChain"/>; the chain is a slice of <see cref="Eligible"/>; and every member of
/// <see cref="Eligible"/> carries an allowing <see cref="AiGovernanceDecision"/> that was evaluated
/// for this request, this classification and this destination. There is no code path in which a
/// failover consults a source of candidates that governance has not seen, because there is no other
/// source of candidates.
/// </para>
/// <para>
/// <see cref="Selected"/> is <c>Eligible[0]</c> when the status is
/// <see cref="AiRoutingStatus.Routed"/>, so a consumer may read either. They are separate members
/// because the nullability is the point: a consumer that had to check <c>Eligible.Count &gt; 0</c>
/// before every dereference would eventually forget, and the forgetting would be a null dereference on
/// exactly the path where nothing was serviceable.
/// </para>
/// </remarks>
public sealed record AiRoutingOutcome
{
    /// <summary>The caller's request identifier, echoed so the outcome is joinable to the request.</summary>
    public required string RequestId { get; init; }

    /// <summary>What was asked for.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>What the router concluded.</summary>
    public required AiRoutingStatus Status { get; init; }

    /// <summary>The selected route, when one was selected. Null on every refusal.</summary>
    public AiRoutingCandidate? Selected { get; init; }

    /// <summary>
    /// The routes a failover may walk, in preference order, excluding the selected one.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Truncated to the configured fallback depth, so an estate can bound how many providers a single
    /// caller request may touch. An empty chain is the correct and expected answer on an estate with
    /// one route per capability, and it means "if the primary fails, fail" rather than "try anything".
    /// </para>
    /// <para>
    /// <b>Every member is individually governed.</b> A chain entry is not permitted because it is in
    /// the chain; it is in the chain because it was permitted. Each carries its own
    /// <see cref="AiRoutingCandidate.Governance"/>, so a failover can report which rule permitted the
    /// route it fell back to, which is the question an audit asks after a degradation.
    /// </para>
    /// </remarks>
    public IReadOnlyList<AiRoutingCandidate> FallbackChain { get; init; } = [];

    /// <summary>Every permitted route, in rank order, with the selected route first.</summary>
    public IReadOnlyList<AiRoutingCandidate> Eligible { get; init; } = [];

    /// <summary>Every route that was considered and refused, with the gate that refused it.</summary>
    public IReadOnlyList<AiRoutingRejection> Rejected { get; init; } = [];

    /// <summary>
    /// Every operational gate finding across every candidate, eligible or not.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>W7E's operational stage reports here as well as through <see cref="Rejected"/>.</b> The two
    /// are not duplicates: <see cref="Rejected"/> answers "why was this route not used", and this
    /// answers "what did the operational gates conclude", including about routes that <em>were</em>
    /// used. A candidate that passed reliability on a thin sample and passed a budget by a narrow
    /// margin is a finding an operator wants and a rejection list cannot carry, because nothing was
    /// rejected.
    /// </para>
    /// <para>
    /// Empty when the operational stage did not run. That is a different fact from "the operational
    /// gates found nothing", and the estate distinguishes them by whether the router was composed
    /// with an operational eligibility port.
    /// </para>
    /// </remarks>
    public IReadOnlyList<AiOperationalRejection> OperationalFindings { get; init; } = [];

    /// <summary>
    /// What the operational gates concluded about the selected route, where the stage ran.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>The complement of <see cref="OperationalFindings"/>, not a duplicate of it.</b> Findings
    /// reports gates that <em>refused</em> something; this reports the verdict on the route that was
    /// chosen, which by definition refused nothing — its budget decision, the reliability evidence it
    /// passed on, and the price quote its projection came from. An operator asking "on what evidence
    /// was this route admitted" is asking this question, and a rejection list cannot answer it.
    /// </para>
    /// <para>
    /// Null when the operational stage did not run, which is a different fact from a stage that ran and
    /// found nothing to say.
    /// </para>
    /// </remarks>
    public AiOperationalVerdict? SelectedOperational { get; init; }

    /// <summary>
    /// The governance decision governing this outcome: the request-scope decision combined with the
    /// selected route's, most restrictively.
    /// </summary>
    /// <remarks>
    /// One decision rather than two, because a consumer that had to combine them would eventually
    /// combine them permissively. The combination is
    /// <see cref="AiGovernanceDecision.Combine"/>, which can only ever tighten,
    /// so no route selection can produce an outcome more permissive than the request-scope decision
    /// that admitted it.
    /// </remarks>
    public required AiGovernanceDecision Governance { get; init; }

    /// <summary>A caller-safe explanation of the status. Never a provider error body or a credential.</summary>
    public string? Reason { get; init; }

    /// <summary>The typed failure for a refusal, or null when routed.</summary>
    public AiFailure? Failure { get; init; }

    /// <summary>True when a route was selected and governance permitted it.</summary>
    public bool IsRouted => Status is AiRoutingStatus.Routed;

    /// <summary>True when a named human must decide before this work may proceed.</summary>
    public bool RequiresHumanDecision => Status is AiRoutingStatus.HumanDecisionRequired;
}
