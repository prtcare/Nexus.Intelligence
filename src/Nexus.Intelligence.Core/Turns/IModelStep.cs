using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

public interface IModelStep
{
    Task<ModelStepResult> InvokeAsync(
        AssembledPrompt prompt,
        ModelDescriptor model,
        IReadOnlyList<ToolDescriptor> tools,
        InvocationIdentity identity,
        decimal? maxCost,
        CancellationToken ct = default);
}
