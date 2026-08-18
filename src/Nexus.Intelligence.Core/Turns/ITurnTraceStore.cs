namespace Nexus.Intelligence.Core.Turns;

public interface ITurnTraceStore
{
    Task AddAsync(TurnTrace trace, CancellationToken ct = default);

    Task<TurnTrace?> GetAsync(string turnId, CancellationToken ct = default);

    Task<TurnTrace?> FindByIdempotencyKeyAsync(string tenantId, string productId, string idempotencyKey, CancellationToken ct = default);
}
