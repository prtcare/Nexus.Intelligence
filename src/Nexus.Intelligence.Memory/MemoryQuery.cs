using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Memory;

public sealed record MemoryQuery
{
    public required string TenantId { get; init; }
    public required string ProductId { get; init; }
    public ScopeRef? Scope { get; init; }
    public MemoryKind? Kind { get; init; }
    public int MaxItems { get; init; } = 20;
}
