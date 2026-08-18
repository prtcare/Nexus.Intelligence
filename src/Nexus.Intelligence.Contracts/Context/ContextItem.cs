namespace Nexus.Intelligence.Contracts;

public sealed record ContextItem
{
    public required string Id { get; init; }
    public required ContextItemKind Kind { get; init; }
    public string? Title { get; init; }
    public required string Body { get; init; }
    public required TrustLevel Trust { get; init; }
    public DateTimeOffset? OccurredAt { get; init; }
    public string? Author { get; init; }
    public double? RelevanceHint { get; init; }
    public IReadOnlyDictionary<string, string> Tags { get; init; } = new Dictionary<string, string>();
}
