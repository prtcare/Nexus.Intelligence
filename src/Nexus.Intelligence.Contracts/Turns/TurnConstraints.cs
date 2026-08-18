namespace Nexus.Intelligence.Contracts;

public sealed record TurnConstraints
{
    public decimal? MaxCost { get; init; }
    public TimeSpan? LatencyBudget { get; init; }
    public IReadOnlyList<string> AllowedTools { get; init; } = [];
    public bool RequireApprovalForWrites { get; init; } = true;
    public string? ModelHint { get; init; }
    public static TurnConstraints Default { get; } = new();
}
