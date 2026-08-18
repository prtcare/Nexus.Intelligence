using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public sealed record TurnTrace
{
    public required string TurnId { get; init; }
    public required IntelligenceTurnRequest Request { get; init; }
    public required IReadOnlyList<DecisionTrace> Decisions { get; init; }
    public required IntelligenceTurnResponse Response { get; init; }
    public required DateTimeOffset CreatedAt { get; init; }
}
