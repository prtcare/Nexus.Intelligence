namespace Nexus.Intelligence.Context.Ranking;

public sealed record RankingOptions
{
    public int MaxItems { get; init; } = 50;
    public double RecencyHalfLifeDays { get; init; } = 30;
    public static RankingOptions Default { get; } = new();
}
