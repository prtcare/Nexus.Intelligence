using System.Collections.Concurrent;

namespace Nexus.Intelligence.Core.Turns;

public sealed class InMemoryTurnTraceStore : ITurnTraceStore
{
    private readonly ConcurrentDictionary<string, TurnTrace> _traces = new();
    private readonly ConcurrentDictionary<string, string> _idempotencyIndex = new();

    public Task AddAsync(TurnTrace trace, CancellationToken ct = default)
    {
        _traces[trace.TurnId] = trace;
        _idempotencyIndex[IndexKey(trace.Request.TenantId, trace.Request.ProductId, trace.Request.IdempotencyKey)] = trace.TurnId;
        return Task.CompletedTask;
    }

    public Task<TurnTrace?> GetAsync(string turnId, CancellationToken ct = default)
    {
        _traces.TryGetValue(turnId, out var trace);
        return Task.FromResult(trace);
    }

    public Task<TurnTrace?> FindByIdempotencyKeyAsync(string tenantId, string productId, string idempotencyKey, CancellationToken ct = default)
    {
        if (_idempotencyIndex.TryGetValue(IndexKey(tenantId, productId, idempotencyKey), out var turnId) &&
            _traces.TryGetValue(turnId, out var trace))
        {
            return Task.FromResult<TurnTrace?>(trace);
        }

        return Task.FromResult<TurnTrace?>(null);
    }

    private static string IndexKey(string tenantId, string productId, string idempotencyKey) =>
        $"{tenantId}|{productId}|{idempotencyKey}";
}
