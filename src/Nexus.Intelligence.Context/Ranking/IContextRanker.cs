using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Context.Ranking;

public interface IContextRanker
{
    IReadOnlyList<RankedContextItem> Rank(
        ContextBundle bundle, string query, RankingOptions options);
}
