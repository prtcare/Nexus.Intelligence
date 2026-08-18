using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

public interface IToolLoop
{
    Task<ToolLoopResult> RunAsync(
        ModelInvocationResult initialResult,
        AssembledPrompt prompt,
        ModelDescriptor model,
        IReadOnlyList<ToolDescriptor> availableTools,
        PolicyVerdict policy,
        TurnConstraints constraints,
        InvocationIdentity identity,
        CancellationToken ct = default);
}
