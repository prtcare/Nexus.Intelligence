using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Core;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

/// <summary>
/// One further model invocation, supplied to the tool loop by whoever is governing the execution.
/// </summary>
/// <remarks>
/// <para>
/// <b>This delegate is the fix for a governance hole W7D found, and the hole was not obvious.</b> The
/// tool loop re-invokes the model after every round of tool results, up to its iteration bound. Before
/// this delegate existed, the loop held an <c>IModelGateway</c> and called it directly — so a single
/// governed first invocation could be followed by up to four more provider calls that no governance
/// decision had considered. The gate was passed once and the door stayed open.
/// </para>
/// <para>
/// A loop that re-invokes a model is a loop that spends money and consumes a context window repeatedly,
/// and each round is a separate question for a budget rule. Handing the loop a continuation instead of a
/// gateway means the loop cannot invoke anything itself: the continuation is built by the governed path,
/// so every round passes the same gate the first round did.
/// </para>
/// </remarks>
/// <param name="messages">The conversation so far, including the tool results just gathered.</param>
/// <param name="ct">Cancels the invocation.</param>
public delegate Task<ModelStepResult> ContinuationInvocation(
    IReadOnlyList<ModelMessage> messages,
    CancellationToken ct);

/// <summary>
/// Executes the tool calls a model asked for, and returns the conversation's final state.
/// </summary>
/// <remarks>
/// <b>It holds a tool gateway and no model gateway.</b> The asymmetry is the design: tool invocation is
/// governed before the loop is entered, so the loop may call the tool gateway directly, while model
/// invocation is governed per round, so the loop reaches it only through
/// <see cref="ContinuationInvocation"/>.
/// </remarks>
public interface IToolLoop
{
    /// <summary>Runs the tool loop until the model stops asking for tools or the iteration bound is reached.</summary>
    /// <param name="initialResult">The first model reply, already invoked under governance.</param>
    /// <param name="prompt">The assembled prompt the conversation started from.</param>
    /// <param name="availableTools">The tools governance permitted for this execution.</param>
    /// <param name="policy">What the caller permits the loop to do, including which tools.</param>
    /// <param name="constraints">The caller's turn constraints, including the write-approval posture.</param>
    /// <param name="identity">The caller's identity.</param>
    /// <param name="continueInvocation">The governed way to ask the model for another round.</param>
    /// <param name="ct">Cancels the loop.</param>
    Task<ToolLoopResult> RunAsync(
        ModelInvocationResult initialResult,
        AssembledPrompt prompt,
        IReadOnlyList<ToolDescriptor> availableTools,
        PolicyVerdict policy,
        TurnConstraints constraints,
        InvocationIdentity identity,
        ContinuationInvocation continueInvocation,
        CancellationToken ct = default);
}
