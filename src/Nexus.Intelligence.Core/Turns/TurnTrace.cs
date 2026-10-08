using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public sealed record TurnTrace
{
    public required string TurnId { get; init; }
    public required IntelligenceTurnRequest Request { get; init; }
    public required IReadOnlyList<DecisionTrace> Decisions { get; init; }
    public required IntelligenceTurnResponse Response { get; init; }
    public required DateTimeOffset CreatedAt { get; init; }

    /// <summary>
    /// The audit record written for this turn's execution, where one was written.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>W7E TASK 10. The trace references the evidence; the evidence does not reference the
    /// trace.</b> The two are not duplicates and must not be made into duplicates:
    /// </para>
    /// <list type="bullet">
    /// <item>
    /// <see cref="TurnTrace"/> is the <b>execution trace</b> — the ordered narrative of what each
    /// stage decided and why, which the Product's explanation surface reads. It is keyed by turn and
    /// is produced for every turn, including the ones refused before any provider was reached.
    /// </item>
    /// <item>
    /// <see cref="AiAuditRecord"/> is the <b>governance and audit evidence</b> — the structured,
    /// sanitized record of what was asked, what governed it, what served it, what it consumed and what
    /// it cost. It is the record an auditor resolves an <c>AiExecutionReference</c> against, and it is
    /// the only place provider and model identity is written.
    /// </item>
    /// </list>
    /// <para>
    /// Neither is derived from the other and neither is a summary of the other: the trace does not
    /// carry cost, tokens or provider identity, and the audit record does not carry the decision
    /// narrative. This field is the join, and it points one way so that "what did governance decide"
    /// has exactly one answer.
    /// </para>
    /// </remarks>
    public string? AuditReference { get; init; }
}
