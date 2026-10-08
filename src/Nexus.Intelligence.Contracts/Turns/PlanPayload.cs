namespace Nexus.Intelligence.Contracts;

/// <summary>
/// What a planning request produced, as a member rather than as something inferred from an empty list.
/// </summary>
/// <remarks>
/// <para>
/// <b>W10.7A. Before this, a governed refusal and a legitimately empty plan were the same value.</b>
/// The planner turned a refusal into <c>new PlanPayload([])</c> and the endpoint answered HTTP 200, so
/// the two serialized to identical bytes and a caller could not tell "the estate permitted this and the
/// model returned nothing" from "the estate refused to plan at all".
/// </para>
/// <para>
/// <b>The shape follows <see cref="IntelligenceTurnResponse"/>, deliberately.</b> That record — this
/// estate's other governed entry point — carries its outcome as a member (<c>Outcome</c> plus a typed
/// failure) rather than being wrapped in a second envelope. Planning reuses that convention under the
/// same member name instead of introducing a parallel result framework, and the response record stays
/// the thing a caller reads.
/// </para>
/// <para>
/// <b>Append-only.</b> Members are added at the end and never renumbered: this vocabulary is carried
/// across a wire contract.
/// </para>
/// </remarks>
public enum PlanOutcomeKind
{
    /// <summary>A plan was produced, with steps.</summary>
    Available = 0,

    /// <summary>
    /// The estate permitted the planning and the model returned nothing usable. A successful
    /// non-answer: the request was executed and there is simply no plan in it.
    /// </summary>
    Empty = 1,

    /// <summary>
    /// The estate refused to plan. <b>No plan was produced, and no provider was asked.</b> Carries
    /// <see cref="PlanPayload.Refusal"/>.
    /// </summary>
    Refused = 2,
}

/// <summary>Why a planning request was refused, in the estate's own vocabulary.</summary>
/// <remarks>
/// The refusal is described by the decision that produced it, so a caller sees the ground the trace and
/// the audit record already carry. It deliberately omits the rules that were applied: a caller needs to
/// know that it was refused and on what ground, not the estate's internal policy inventory.
/// </remarks>
public sealed record PlanRefusal
{
    /// <summary>A stable, machine-readable reason. Safe to branch on; never prose.</summary>
    public required string ReasonCode { get; init; }

    /// <summary>A human-safe sentence. Names no rule inventory and no internal identifier.</summary>
    public required string Message { get; init; }

    /// <summary>The governance decision's rule identifier, where a rule refused it.</summary>
    public string? RuleId { get; init; }
}

/// <summary>The result of a planning request.</summary>
/// <remarks>
/// <b>The outcome is a member rather than something a caller derives from <see cref="Steps"/>.</b> An
/// empty step list is a legitimate answer to a permitted request, so deriving the outcome from it would
/// make the two cases one value again — which is the defect this member exists to close.
/// </remarks>
public sealed record PlanPayload(IReadOnlyList<PlanStep> Steps)
{
    /// <summary>
    /// Which of the three outcomes this is. Defaults to <see cref="PlanOutcomeKind.Available"/> so an
    /// existing producer that sets only <see cref="Steps"/> keeps its current meaning.
    /// </summary>
    public PlanOutcomeKind Outcome { get; init; } = PlanOutcomeKind.Available;

    /// <summary>
    /// Why the request was refused — present exactly when <see cref="Outcome"/> is
    /// <see cref="PlanOutcomeKind.Refused"/>.
    /// </summary>
    /// <remarks>
    /// <b>Null on the other two outcomes, and null is the assertion that nothing refused this.</b> A
    /// refusal with no refusal, or a permitted plan carrying one, would each be a contract that
    /// contradicts itself.
    /// </remarks>
    public PlanRefusal? Refusal { get; init; }
}
