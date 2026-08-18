using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Memory;

public sealed record MemoryRecord
{
    public required string Id { get; init; }
    public required string TenantId { get; init; }
    public required string ProductId { get; init; }
    public required ScopeRef Scope { get; init; }
    public required MemoryKind Kind { get; init; }
    public required string Content { get; init; }
    public required TrustLevel Trust { get; init; }
    public required DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset? ExpiresAt { get; init; }
    public IReadOnlyList<string> Tags { get; init; } = [];
}
