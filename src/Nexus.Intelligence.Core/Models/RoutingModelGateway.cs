using Nexus.Platform.Contracts.Models;

namespace Nexus.Platform.Core.Models;

public sealed class RoutingModelGateway(IEnumerable<INamedModelGateway> gateways) : IModelGateway
{
    public Task<ModelInvocationResult> InvokeAsync(ModelInvocation invocation, CancellationToken ct = default)
    {
        var gateway = Resolve(invocation.ModelId);
        if (gateway is null)
        {
            // W7G.1 Gate 7. No vendor serves this model, which is the taxonomy's ModelUnavailable word
            // for word - "the selected model is unavailable, retired or not served by any healthy
            // provider". It is classified rather than left null because this decision is taken here, by
            // this estate, and is not a vendor failure that arrived from below: the vendor was never
            // reached, so nothing below this line could have classified it.
            //
            // The category is retryable and is an unavailability, exactly as the ProviderUnavailable it
            // used to collapse into was, so the failover plane's behaviour is unchanged; only the fact
            // reported to an operator becomes the true one.
            return Task.FromResult(new ModelInvocationResult
            {
                Success = false,
                Error = $"No model gateway registered for '{invocation.ModelId}'.",
                Failure = ModelFailureKind.ModelUnavailable,
                ModelUsed = invocation.ModelId
            });
        }

        return gateway.InvokeAsync(invocation, ct);
    }

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
