namespace Nexus.Intelligence.Contracts;

/// <summary>
/// An opaque, resolvable handle to one AI execution.
/// </summary>
/// <remarks>
/// <para>
/// This is what a caller receives in place of "which provider and model ran my request". It is the
/// entire design in one type: the caller can correlate, dispute and reference an execution, and an
/// operator or auditor holding authority can resolve the identifier against the AI Head's own audit
/// surface to learn the provider, model, version and region that served it. The caller learns
/// <em>that</em> it happened, not <em>who did it</em>.
/// </para>
/// <para>
/// It is deliberately a single opaque string. A structured reference with a provider field, even a
/// hashed one, would be a provider field — and a stable hash of a provider name is a provider name
/// for anyone who can guess the small set of names, which is everyone.
/// </para>
/// </remarks>
public sealed record AiExecutionReference
{
    /// <summary>
    /// The AI Head's execution identifier. Opaque; callers must not parse it or infer anything from
    /// its shape, because its shape is not part of the contract and may change.
    /// </summary>
    public required string ExecutionId { get; init; }

    public override string ToString() => ExecutionId;
}

/// <summary>
/// What a caller receives from an AI capability invocation.
/// </summary>
/// <remarks>
/// <para>
/// The caller-facing projection of <see cref="AiExecutionResult"/>. The projection exists to remove
/// exactly two things — <c>ProviderUsed</c> and <c>ModelUsed</c> — and to replace them with
/// <see cref="AiExecutionReference"/>. Everything a caller legitimately needs is present: the output,
/// the citations, the usage and cost it may be billed for, the policy verdict that governs it, the
/// timing that bounds it, and the audit reference that lets it be disputed.
/// </para>
/// <para>
/// A failure never travels as an exception here. It travels as
/// <see cref="AiExecutionResult.Failure"/> on a non-success <see cref="Status"/>, so that a caller
/// with a deterministic fallback is not forced into a try/catch to find it. The one exception is
/// <see cref="AiCapabilityException"/>, which exists for implementation layers inside the boundary.
/// </para>
/// </remarks>
public sealed record AiCapabilityResponse
{
    /// <summary>The caller's request identifier, echoed.</summary>
    public required string RequestId { get; init; }

    /// <summary>The capability that was requested, echoed so a multiplexed caller can route the answer.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>Correlates this response with the request and across services.</summary>
    public required string CorrelationId { get; init; }

    /// <summary>How the execution ended.</summary>
    public required AiExecutionStatus Status { get; init; }

    /// <summary>The unstructured output, where one was produced.</summary>
    public string? Output { get; init; }

    /// <summary>The structured output, where the response contract asked for one.</summary>
    public string? StructuredOutput { get; init; }

    /// <summary>Sources the output cites.</summary>
    public IReadOnlyList<Citation> Citations { get; init; } = [];

    /// <summary>Tokens consumed, for a caller that meters its own usage.</summary>
    public AiTokenUsage Usage { get; init; } = AiTokenUsage.None;

    /// <summary>What the execution cost.</summary>
    public AiCost? Cost { get; init; }

    /// <summary>
    /// How long the caller waited.
    /// </summary>
    /// <remarks>
    /// One elapsed value, not the AI Head's own <see cref="AiTiming"/> breakdown. The breakdown names
    /// provider time, and the caller projection exists to remove provider-shaped detail — a caller
    /// that can distinguish "provider time" from "pre-execution time" is reading the AI Head's internal
    /// structure, and it is not a distinction it can act on. What a caller can act on is its own
    /// latency budget, which needs the total and nothing else.
    /// </remarks>
    public TimeSpan? Elapsed { get; init; }

    /// <summary>What policy decided. Present on every response, including successes.</summary>
    public AiPolicyDecision? PolicyDecision { get; init; }

    /// <summary>What evaluation concluded, where evaluation ran.</summary>
    public AiEvaluationResult Evaluation { get; init; } = AiEvaluationResult.NotEvaluated;

    /// <summary>The typed failure, present exactly when the execution did not succeed.</summary>
    public AiFailure? Failure { get; init; }

    /// <summary>
    /// The opaque handle to this execution. <b>Absent on a degraded result</b>, because nothing ran:
    /// there is no execution to reference, and the absence is the label.
    /// </summary>
    public AiExecutionReference? Execution { get; init; }

    /// <summary>The AI Head's audit record for this execution.</summary>
    public string? AuditReference { get; init; }

    /// <summary>
    /// True when the work was served by a route other than the one the AI Head selected first.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>W7F TASK 3.</b> A caller is told <em>that</em> a fallback happened without being told
    /// <em>what</em> it fell back to, which is the same arrangement
    /// <see cref="Execution"/> makes for provider and model identity: a fact the caller can act on,
    /// with the identity withheld. It is a caller-facing fact rather than an internal one because it
    /// is the only signal a caller has that the answer it received came from a secondary route — and a
    /// caller that has been told to expect a specific quality, or that is deciding whether to re-ask,
    /// is entitled to know that.
    /// </para>
    /// <para>
    /// <b>It is not <see cref="IsDegraded"/>, and neither implies the other.</b> A degraded response
    /// means nothing ran and no AI answer exists; a fallback completed and produced a real answer on a
    /// different route. A response can be a successful fallback (<c>IsDegraded = false</c>,
    /// <c>UsedFallback = true</c>) and it can be degraded with no fallback attempted
    /// (<c>IsDegraded = true</c>, <c>UsedFallback = false</c>). The default of <c>false</c> states that
    /// no fallback was recorded, which is the reading that claims nothing extra happened.
    /// </para>
    /// <para>
    /// The failover's own detail — which route lost, which replaced it, and why — stays on the
    /// operations surface, where it is resolvable under authority. A caller receiving a fallback
    /// between two routes it cannot name would be reading the AI Head's routing, which is the thing the
    /// boundary exists to hide.
    /// </para>
    /// </remarks>
    public bool UsedFallback { get; init; }

    /// <summary>True when the deterministic path was taken rather than the AI path.</summary>
    /// <remarks>
    /// The label the degradation rules require. An <see cref="AiDependencyClass.AiEnhanced"/> caller
    /// must be able to tell the user that the enhanced path was not taken; a caller cannot infer that
    /// from <see cref="Status"/> alone without also knowing which statuses mean "unavailable" rather
    /// than "refused", so it is stated rather than derived.
    /// </remarks>
    public bool IsDegraded { get; init; }

}
