using Nexus.Platform.Contracts.Models;

namespace Nexus.Platform.Core.Models;

public sealed class AggregatingModelCatalog(IEnumerable<IModelCatalogSource> sources) : IModelCatalog
{
    public async Task<IReadOnlyList<ModelDescriptor>> ListAsync(ModelQuery query, CancellationToken ct = default)
    {
        var descriptors = new List<ModelDescriptor>();

        foreach (var source in sources)
        {
            descriptors.AddRange(await source.ListAsync(ct));
        }

        return descriptors.Where(d => Matches(d, query)).ToList();
    }

    private static bool Matches(ModelDescriptor descriptor, ModelQuery query)
    {
        if (query.Vendor is not null &&
            !string.Equals(descriptor.Vendor, query.Vendor, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (query.RequiredCapabilities is { } required &&
            (descriptor.Capabilities & required) != required)
        {
            return false;
        }

        if (query.MinContextWindow is { } minContextWindow &&
            descriptor.ContextWindow < minContextWindow)
        {
            return false;
        }

        if (query.MaxCostPer1kIn is { } maxCostPer1kIn &&
            descriptor.CostPer1kIn > maxCostPer1kIn)
        {
            return false;
        }

        return true;
    }
}
