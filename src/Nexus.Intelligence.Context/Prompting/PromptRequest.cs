using Nexus.Intelligence.Context.Ranking;

namespace Nexus.Intelligence.Context.Prompting;

public sealed record PromptRequest
{
    public required string UserInput { get; init; }
    public required IReadOnlyList<RankedContextItem> Context { get; init; }
    public required int ContextWindowTokens { get; init; }
    public string? SystemFrame { get; init; }
}
