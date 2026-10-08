namespace Nexus.Intelligence.Contracts;

/// <summary>
/// A provider-independent request for AI work. The caller names <em>what it wants done</em>; it does
/// not name who should do it.
/// </summary>
/// <remarks>
/// <para>
/// <b>There is no provider, vendor, model, endpoint or credential field on this type, and there must
/// never be one.</b> That absence is the contract, not a convention: a caller cannot pin a model
/// because there is nowhere to write one, and it cannot reach a provider because the only thing it
/// receives back is an opaque <see cref="AiExecutionReference"/>. Provider and model appear in the
/// AI Head's own <see cref="AiExecutionResult"/> as <em>evidence of what happened</em>, never here as
/// instruction about what should.
/// </para>
/// <para>
/// This is additive to the existing <see cref="IntelligenceTurnRequest"/>, which continues to carry
/// conversational turns. The relationship is deliberate: a turn is one capability
/// (<see cref="AiCapabilities.ChatComplete"/>) with an established envelope, and rewriting that
/// envelope to prove a point would break the Chat product for no architectural gain. The two are
/// expected to converge when <see cref="IntelligenceTurnRequest"/>'s turn-shaped members are
/// generalised — that convergence is a later lane's work, not W7A's.
/// </para>
/// </remarks>
public sealed record AiCapabilityRequest
{
    /// <summary>
    /// The caller's identifier for this request. Echoed on the result so a caller can correlate, and
    /// used as the audit join key. Must be unique per caller per attempt.
    /// </summary>
    public required string RequestId { get; init; }

    /// <summary>
    /// The semantic capability being requested, e.g. <c>code.review</c>.
    /// </summary>
    /// <remarks>
    /// The single field that decides everything downstream: which role resolves, which model
    /// capabilities are required, which prompt version applies and which policy governs. An
    /// unresolvable capability is the failure <see cref="AiFailureCategory.CapabilityNotFound"/>, not
    /// a request that silently runs on a default model.
    /// </remarks>
    public required CapabilityId Capability { get; init; }

    /// <summary>
    /// Why the caller is asking, in the caller's own words.
    /// </summary>
    /// <remarks>
    /// Required, and not derivable. The existing pipeline records <em>what</em> it decided
    /// (<see cref="DecisionTrace"/>) but never <em>why the caller wanted it</em>, which makes "why did
    /// this AI action happen" unanswerable after the fact. It is free text and is stored in the audit
    /// record as metadata; it is never treated as an instruction to the model.
    /// </remarks>
    public required string Purpose { get; init; }

    /// <summary>Who is asking, and within what scope.</summary>
    public required AiRequesterIdentity Requester { get; init; }

    /// <summary>The caller's input for this capability.</summary>
    public required TurnInput Input { get; init; }

    /// <summary>
    /// References to the context the capability may draw on, in the canonical flattened shape.
    /// </summary>
    /// <remarks>
    /// Reuses <see cref="ContextBundle"/> unchanged rather than introducing a parallel reference type.
    /// The AI Head receives bodies, not pointers to product storage: it never reads a product's
    /// database, so "reference" here means "the caller already resolved this and is handing it over".
    /// The bundle is what the exposure policy inspects and what the context builder filters.
    /// </remarks>
    public ContextBundle Context { get; init; } = ContextBundle.Empty;

    /// <summary>
    /// How sensitive the request is. Required, with <b>no default</b>.
    /// </summary>
    /// <remarks>
    /// The absence of a default is the control. A default of <see cref="DataClassification.Internal"/>
    /// would mean a caller that forgot to classify <see cref="DataClassification.Pii"/> content
    /// silently downgraded its protection, and nothing in the system could tell the difference between
    /// "deliberately internal" and "nobody thought about it". Making the field <c>required</c> moves
    /// that from a runtime silence to a compile error.
    /// </remarks>
    public required DataClassification Classification { get; init; }

    /// <summary>What the caller requires of the execution: time, cost, quality, degradation.</summary>
    public AiExecutionPolicy Execution { get; init; } = AiExecutionPolicy.Default;

    /// <summary>What the execution may do, as opposed to read. Defaults to nothing.</summary>
    public ToolPermissionProfile Tools { get; init; } = ToolPermissionProfile.None;

    /// <summary>The shape of answer required.</summary>
    public AiResponseContract Response { get; init; } = AiResponseContract.Text;

    /// <summary>
    /// Ties this request to a wider caller-side operation across services. Optional; when absent,
    /// <see cref="RequestId"/> is the only correlation key.
    /// </summary>
    public string? CorrelationId { get; init; }

    /// <summary>
    /// Makes a retry of the same logical request safe: the AI Head may return the original result
    /// rather than executing twice.
    /// </summary>
    /// <remarks>
    /// Distinct from <see cref="RequestId"/>. A caller legitimately re-requesting after a degradation
    /// is making a <em>new</em> request with a new id; a caller retrying a transport failure is
    /// repeating the <em>same</em> request and must keep the same idempotency key.
    /// </remarks>
    public required string IdempotencyKey { get; init; }
}
