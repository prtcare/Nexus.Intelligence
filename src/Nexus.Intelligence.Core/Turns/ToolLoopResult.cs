using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Turns;

public sealed record ToolLoopResult(
    ModelInvocationResult FinalResult,
    IReadOnlyList<ProposedAction> ProposedActions,
    ModelUsage AccumulatedUsage,
    IReadOnlyList<DecisionTrace> Decisions)
{
    /// <summary>
    /// The tools the loop actually invoked, in the order it invoked them, by identifier.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>W7E TASK 8 needs this, and the decision traces cannot supply it.</b> The audit record carries
    /// "tools used", and the only other place a tool identifier appears is inside the free text of a
    /// trace line — so deriving the list from the traces would mean parsing a sentence this type wrote,
    /// which breaks the first time the sentence is reworded.
    /// </para>
    /// <para>
    /// <b>It is invoked tools, not offered tools and not proposed tools.</b> An identifier the caller
    /// offered and the loop never called is covered by the governance decision on the request; an
    /// identifier the loop proposed for approval and did not execute is in
    /// <see cref="ProposedActions"/>. This is the third thing: what actually ran.
    /// </para>
    /// </remarks>
    public IReadOnlyList<string> InvokedToolIds { get; init; } = [];
}
