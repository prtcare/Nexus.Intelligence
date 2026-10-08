namespace Nexus.Platform.Contracts.Models;

public interface IModelCatalog
{
    Task<IReadOnlyList<ModelDescriptor>> ListAsync(ModelQuery query, CancellationToken ct = default);
}
