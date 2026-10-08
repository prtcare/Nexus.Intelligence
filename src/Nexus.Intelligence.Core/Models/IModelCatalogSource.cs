using Nexus.Platform.Contracts.Models;

namespace Nexus.Platform.Core.Models;

// Extension point registered by provider packages; AggregatingModelCatalog fans out to all of these.
public interface IModelCatalogSource
{
    Task<IReadOnlyList<ModelDescriptor>> ListAsync(CancellationToken ct = default);
}
