namespace Nexus.Intelligence.Core.Turns;

public sealed record PolicyVerdict
{
    public required bool Allowed { get; init; }
    public IReadOnlyList<string> AllowedTools { get; init; } = [];
    public bool RequireApprovalForWrites { get; init; } = true;
    public string? DenialReason { get; init; }
}
