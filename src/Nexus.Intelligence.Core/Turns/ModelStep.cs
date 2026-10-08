using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Core;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;
using Nexus.Platform.Core.Models;

namespace Nexus.Intelligence.Core.Turns;

/// <summary>
/// Invokes a model through the platform gateway, under a governed model identifier.
/// </summary>
/// <remarks>
/// <para>
/// <b>This type holds no credential, no client and no endpoint.</b> The credential belongs to the
/// adapter below <see cref="IModelGateway"/>, resolved from the approved secret reference by the
/// provider layer — a layer this type cannot reach and has no field to reach it with. That is the same
/// arrangement as before W7D; what changed is who may call it.
/// </para>
/// <para>
/// <b>This is the provider seam, and it is called from exactly one place.</b> Nothing in this type
/// evaluates governance, and it must not: a gate inside the thing being gated is a gate that can be
/// reached around by calling the thing directly. The gate is
/// <see cref="Nexus.Intelligence.Core.Governance.GovernedProviderInvocation"/>, which wraps a call to
/// this method, and this method is only reached through that wrapper or from a test.
/// </para>
/// </remarks>
public sealed class ModelStep : IModelStep
{
    private readonly IUsageReportingModelGateway _gateway;

    /// <summary>Composes the step over the platform model gateway.</summary>
    /// <remarks>
    /// <see cref="IUsageReportingModelGateway"/> rather than <see cref="IModelGateway"/>: the governed
    /// path needs to know whether the provider reported usage, and the Platform port cannot carry that
    /// fact. Both are satisfied by the same registered instance.
    /// </remarks>
    public ModelStep(IUsageReportingModelGateway gateway)
        => _gateway = gateway ?? throw new ArgumentNullException(nameof(gateway));

    /// <inheritdoc />
    public async Task<ModelStepResult> InvokeAsync(
        AssembledPrompt prompt,
        string modelId,
        IReadOnlyList<ToolDescriptor> tools,
        InvocationIdentity identity,
        decimal? maxCost,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(prompt);
        ArgumentException.ThrowIfNullOrWhiteSpace(modelId);
        ArgumentNullException.ThrowIfNull(tools);
        ArgumentNullException.ThrowIfNull(identity);

        var invocation = new ModelInvocation
        {
            ModelId = modelId,
            Messages = prompt.Messages,
            Tools = tools,
            MaxCost = maxCost,
            Identity = identity
        };

        var outcome = await _gateway.InvokeReportingUsageAsync(invocation, ct).ConfigureAwait(false);
        var result = outcome.Result;

        var decision = result.Success
            ? new DecisionTrace(
                $"Invoked model '{modelId}'",
                $"Sent {prompt.Messages.Count} message(s) with {tools.Count} available tool(s)",
                [])
            : new DecisionTrace(
                $"Model '{modelId}' invocation failed",
                result.Error ?? "Unknown model gateway error",
                []);

        // The measurement travels beside the Platform result, which cannot express its absence.
        return new ModelStepResult(result, decision)
        {
            TokensIn = outcome.TokensIn,
            TokensOut = outcome.TokensOut,
        };
    }
}
