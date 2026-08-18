using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

public sealed class ModelStep : IModelStep
{
    private readonly IModelGateway _gateway;

    public ModelStep(IModelGateway gateway)
    {
        _gateway = gateway;
    }

    public async Task<ModelStepResult> InvokeAsync(
        AssembledPrompt prompt,
        ModelDescriptor model,
        IReadOnlyList<ToolDescriptor> tools,
        InvocationIdentity identity,
        decimal? maxCost,
        CancellationToken ct = default)
    {
        var invocation = new ModelInvocation
        {
            ModelId = model.ModelId,
            Messages = prompt.Messages,
            Tools = tools,
            MaxCost = maxCost,
            Identity = identity
        };

        var result = await _gateway.InvokeAsync(invocation, ct);

        var decision = result.Success
            ? new DecisionTrace(
                $"Invoked model '{model.ModelId}'",
                $"Sent {prompt.Messages.Count} message(s) with {tools.Count} available tool(s)",
                [])
            : new DecisionTrace(
                $"Model '{model.ModelId}' invocation failed",
                result.Error ?? "Unknown model gateway error",
                []);

        return new ModelStepResult(result, decision);
    }
}
