namespace Nexus.Intelligence.Contracts;

public sealed record UsageSummary(int TokensIn, int TokensOut, decimal EstimatedCost, string ModelUsed)
{
    public static UsageSummary Zero { get; } = new(0, 0, 0m, string.Empty);
}
