namespace Nexus.Intelligence.Contracts;

public sealed record ProposedAction
{
    public required string ToolRef { get; init; }
    public required IReadOnlyDictionary<string, string> Arguments { get; init; }
    public required bool ApprovalRequired { get; init; }
    public string? Rationale { get; init; }
}
