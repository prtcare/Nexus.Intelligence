namespace Nexus.Intelligence.Contracts;

public sealed record IntelligenceTurnResponse
{
    public required string TurnId { get; init; }
    public required TurnOutcomeKind Outcome { get; init; }
    public ReplyPayload? Reply { get; init; }
    public PlanPayload? Plan { get; init; }
    public IReadOnlyList<ProposedAction> Actions { get; init; } = [];
    public IReadOnlyList<Citation> Citations { get; init; } = [];
    public IReadOnlyList<DecisionTrace> Decisions { get; init; } = [];
    public IReadOnlyList<PersistenceHint> PersistenceHints { get; init; } = [];
    public UsageSummary Usage { get; init; } = UsageSummary.Zero;
    public IReadOnlyList<TurnError> Errors { get; init; } = [];
}
