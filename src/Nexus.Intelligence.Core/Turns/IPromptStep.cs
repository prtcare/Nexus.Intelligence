using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

/// <summary>
/// Assembles the prompt an execution is sent, from a resolved instruction set and admitted context.
/// </summary>
/// <remarks>
/// <para>
/// <b>It takes a token window and an instruction frame, not a <c>ModelDescriptor</c> and an
/// <c>IAgent</c>.</b> W7D changed this signature, and the change is the lane's thesis in miniature. The
/// previous shape accepted a model descriptor — so the step that fits content into a window had to be
/// handed a model, which meant the thing that chose the model had to run first, which meant selection
/// happened before governance. It also accepted an <c>IAgent</c>, and built the system frame from that
/// agent's name and description compiled into C#.
/// </para>
/// <para>
/// Neither is needed to assemble a prompt. A window is a number of tokens, whatever model stated it, and
/// an instruction frame is text, whatever registry it came from. Taking them as values lets the frame
/// arrive from <see cref="IAiPromptRegistry"/> at a version, and lets the window arrive from the routed
/// candidate that governance already permitted — so the governor and the describer are the same object
/// and cannot disagree about which model is being used.
/// </para>
/// </remarks>
public interface IPromptStep
{
    /// <summary>
    /// Assembles the prompt for one execution.
    /// </summary>
    /// <param name="input">The caller's input.</param>
    /// <param name="rankedContext">The admitted, ranked context. Never unfiltered caller context.</param>
    /// <param name="contextWindowTokens">The window the prompt must fit, as the routed candidate states it.</param>
    /// <param name="instructionFrame">
    /// The operator-authored instruction text, resolved from the prompt registry. Empty means no frame.
    /// </param>
    /// <param name="availableTools">The tools governance permitted for this execution.</param>
    PromptStepResult Assemble(
        TurnInput input,
        IReadOnlyList<RankedContextItem> rankedContext,
        int contextWindowTokens,
        string instructionFrame,
        IReadOnlyList<ToolDescriptor> availableTools);
}
