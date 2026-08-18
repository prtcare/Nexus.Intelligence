using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Api.Tooling;

// TODO(V2): replace with Nexus.Platform.Tools' governed tool registry once implemented
// (see Nexus.Platform.Tools/ToolProvider.cs). Until then no tools are offered to a turn.
public sealed class EmptyToolCatalog : IToolCatalog
{
    public Task<IReadOnlyList<ToolDescriptor>> ListAsync(CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<ToolDescriptor>>([]);
}
