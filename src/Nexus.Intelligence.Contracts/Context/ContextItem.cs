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

    /// <summary>
    /// How sensitive this item is, when the caller knows. <see langword="null"/> means undeclared, and
    /// an undeclared item inherits the request's declared classification rather than being assumed
    /// harmless.
    /// </summary>
    /// <remarks>
    /// Optional and additive: the turn pipeline and every existing caller construct
    /// <see cref="ContextItem"/> without it and are unaffected. A capability invocation that attaches a
    /// source more sensitive than the request itself must declare it here, or the exposure path has
    /// nothing to filter on and will treat the item as the request's own classification.
    /// </remarks>
    public DataClassification? Classification { get; init; }

    public IReadOnlyDictionary<string, string> Tags { get; init; } = new Dictionary<string, string>();
}
