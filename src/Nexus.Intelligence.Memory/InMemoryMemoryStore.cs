using System.Collections.Concurrent;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Memory;

public sealed class InMemoryMemoryStore : IMemoryStore
{
    private readonly ConcurrentDictionary<string, MemoryRecord> _records = new();
    private readonly TimeProvider _timeProvider;

    public InMemoryMemoryStore(TimeProvider timeProvider)
    {
        _timeProvider = timeProvider;
    }

    public Task<IReadOnlyList<MemoryRecord>> QueryAsync(MemoryQuery query, CancellationToken ct = default)
    {
        var now = _timeProvider.GetUtcNow();

        IReadOnlyList<MemoryRecord> results = _records.Values
            .Where(record => !IsExpired(record, now))
            .Where(record => record.TenantId == query.TenantId)
            .Where(record => record.ProductId == query.ProductId)
            .Where(record => MatchesScope(record.Scope, query.Scope))
            .Where(record => query.Kind is null || record.Kind == query.Kind)
            .OrderByDescending(record => record.CreatedAt)
            .Take(query.MaxItems)
            .ToList();

        return Task.FromResult(results);
    }

    public Task AddAsync(MemoryRecord record, CancellationToken ct = default)
    {
        _records[record.Id] = record;
        return Task.CompletedTask;
    }

    public Task ExpireAsync(string id, CancellationToken ct = default)
    {
        if (_records.TryGetValue(id, out var existing))
        {
            _records[id] = existing with { ExpiresAt = _timeProvider.GetUtcNow() };
        }

        return Task.CompletedTask;
    }

    private static bool IsExpired(MemoryRecord record, DateTimeOffset now)
    {
        return record.ExpiresAt is { } expiresAt && expiresAt <= now;
    }

    private static bool MatchesScope(ScopeRef recordScope, ScopeRef? queryScope)
    {
        if (queryScope is null)
        {
            return true;
        }

        return recordScope.Kind == queryScope.Kind && recordScope.Key == queryScope.Key;
    }
}
