using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Core;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

/// <summary>
/// Invokes a model for one assembled prompt.
/// </summary>
/// <remarks>
/// <para>
/// <b>It takes a model identifier, not a <c>ModelDescriptor</c>, and that is the point.</b> A descriptor
/// is a <em>description</em>: it carries the vendor, the capability flags, the context window and the
/// price list. A caller that must be handed one to invoke a model has had to obtain one, and the only
/// source of descriptors in this estate is the provider catalogue — so requiring a descriptor here made
/// the catalogue a mandatory stop on the way to every invocation.
/// </para>
/// <para>
/// W7D removed that stop. The model identifier is the whole of what this seam needs, and the only
/// sanctioned source of a model identifier is <see cref="AiRoutingCandidate"/>, which exists only with
/// a governance decision attached to it. An execution therefore cannot reach this method with an
/// identifier governance has not permitted, because it has no other way to obtain one.
/// </para>
/// <para>
/// <b>Those descriptive facts did not stop being needed; they stopped being needed <em>here</em>.</b>
/// The context window is consumed by <see cref="IPromptStep"/> as a number, supplied from the routed
/// candidate. Cost is consumed by the router, from the same candidate. Both now read one object — the
/// governed route — instead of this seam reading a second one and hoping the two agree.
/// </para>
/// </remarks>
public interface IModelStep
{
    /// <summary>
    /// Invokes the model and returns its result with the trace of that attempt.
    /// </summary>
    /// <param name="prompt">The assembled prompt.</param>
    /// <param name="modelId">The routed model identifier, from the candidate governance permitted.</param>
    /// <param name="tools">The tools governance permitted for this execution.</param>
    /// <param name="identity">The caller's identity, as the platform layer models it.</param>
    /// <param name="maxCost">The caller's cost ceiling, where it stated one.</param>
    /// <param name="ct">Cancels the invocation.</param>
    Task<ModelStepResult> InvokeAsync(
        AssembledPrompt prompt,
        string modelId,
        IReadOnlyList<ToolDescriptor> tools,
        InvocationIdentity identity,
        decimal? maxCost,
        CancellationToken ct = default);
}
