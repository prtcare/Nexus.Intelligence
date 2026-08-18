namespace Nexus.Intelligence.Contracts;

/// <summary>The product's data flattened into a canonical shape. THIS IS THE SEAM.</summary>
public sealed record ContextBundle(IReadOnlyList<ContextItem> Items)
{
    public static ContextBundle Empty { get; } = new([]);
}
