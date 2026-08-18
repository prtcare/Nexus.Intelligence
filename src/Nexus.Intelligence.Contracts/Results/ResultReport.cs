namespace Nexus.Intelligence.Contracts;

public sealed record ResultReport
{
    public required string TurnId { get; init; }
    public required string TenantId { get; init; }
    public required string ProductId { get; init; }
    public required ResultOutcome Outcome { get; init; }
    public string? Evidence { get; init; }
    public DateTimeOffset OccurredAt { get; init; }
}
