namespace Nexus.Intelligence.Memory;

public interface IMemoryStore
{
    Task<IReadOnlyList<MemoryRecord>> QueryAsync(MemoryQuery query, CancellationToken ct = default);
    Task AddAsync(MemoryRecord record, CancellationToken ct = default);
    Task ExpireAsync(string id, CancellationToken ct = default);
}
