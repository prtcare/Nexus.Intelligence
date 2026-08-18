namespace Nexus.Intelligence.Contracts;

public sealed record IntelligenceTurnRequest
{
    public required string TenantId { get; init; }
    public required string ProductId { get; init; }
    public required ScopeRef Scope { get; init; }
    public required ActorRef Actor { get; init; }
    public required TurnInput Input { get; init; }
    public ContextBundle Context { get; init; } = ContextBundle.Empty;
    public TurnConstraints Constraints { get; init; } = TurnConstraints.Default;
    public required string IdempotencyKey { get; init; }
    public string? CorrelationId { get; init; }
}
