using Nexus.Platform.Contracts.Models;

namespace Nexus.Platform.Core.Models;

public sealed class RoutingModelGateway(IEnumerable<INamedModelGateway> gateways) : IModelGateway, IUsageReportingModelGateway
{
    /// <summary>
    /// Invokes the vendor that serves the model, keeping whether the provider reported usage.
    /// </summary>
    /// <remarks>
    /// The routed path. It resolves the vendor prefix and delegates to that gateway's richer port, so
    /// the absence of a usage measurement survives routing instead of being flattened here.
    /// </remarks>
    public Task<ModelGatewayOutcome> InvokeReportingUsageAsync(ModelInvocation invocation, CancellationToken ct = default)
    {
        var gateway = Resolve(invocation.ModelId);

        // No vendor serves this model - see InvokeAsync for why the category is classified here rather
        // than left null. There is no measurement either way: no provider was contacted.
        return gateway is null
            ? Task.FromResult(ModelGatewayOutcome.Unmeasured(NoGatewayResult(invocation)))
            : gateway.InvokeReportingUsageAsync(invocation, ct);
    }

    /// <summary>
    /// The Platform-shaped entry point, for consumers that only need the result.
    /// </summary>
    /// <remarks>
    /// <b>A caller using this method cannot tell an unreported usage from a reported zero</b> — Platform's
    /// <see cref="ModelUsage"/> has no way to say so. The governed path therefore uses
    /// <see cref="InvokeReportingUsageAsync"/>; this exists because <see cref="IModelGateway"/> requires
    /// it, and it is a projection that discards the distinction on purpose.
    /// </remarks>
    public async Task<ModelInvocationResult> InvokeAsync(ModelInvocation invocation, CancellationToken ct = default)
        => (await InvokeReportingUsageAsync(invocation, ct).ConfigureAwait(false)).Result;

    /// <summary>The rejection for a model no registered vendor serves.</summary>
    /// <remarks>
    /// W7G.1 Gate 7. No vendor serves this model, which is the taxonomy's ModelUnavailable word for
    /// word - "the selected model is unavailable, retired or not served by any healthy provider". It is
    /// classified rather than left null because this decision is taken here, by this estate, and is not
    /// a vendor failure that arrived from below: the vendor was never reached, so nothing below this
    /// line could have classified it.
    ///
    /// The category is retryable and is an unavailability, exactly as the ProviderUnavailable it used to
    /// collapse into was, so the failover plane's behaviour is unchanged; only the fact reported to an
    /// operator becomes the true one.
    /// </remarks>
    private static ModelInvocationResult NoGatewayResult(ModelInvocation invocation) => new()
    {
        Success = false,
        Error = $"No model gateway registered for '{invocation.ModelId}'.",
        Failure = ModelFailureKind.ModelUnavailable,
        ModelUsed = invocation.ModelId
    };

    public IAsyncEnumerable<ModelStreamChunk> StreamAsync(ModelInvocation invocation, CancellationToken ct = default)
    {
        var gateway = Resolve(invocation.ModelId)
            ?? throw new InvalidOperationException($"No model gateway registered for '{invocation.ModelId}'.");

        return gateway.StreamAsync(invocation, ct);
    }

    private INamedModelGateway? Resolve(string modelId)
    {
        var separator = modelId.IndexOf(':');
        var vendor = separator >= 0 ? modelId[..separator] : modelId;

        return gateways.FirstOrDefault(g => string.Equals(g.Vendor, vendor, StringComparison.OrdinalIgnoreCase));
    }
}
