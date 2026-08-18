namespace Nexus.Intelligence.Contracts;

public sealed record PlanStep
{
    public required string Id { get; init; }
    public required string Title { get; init; }
    public string? Description { get; init; }
    public IReadOnlyList<string> DependsOn { get; init; } = [];
    public string? AcceptanceCriteria { get; init; }
}
