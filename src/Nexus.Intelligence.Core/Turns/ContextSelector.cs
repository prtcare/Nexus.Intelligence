using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public sealed class ContextSelector : IContextSelector
{
    private readonly IContextRanker _ranker;

    public ContextSelector(IContextRanker ranker)
    {
        _ranker = ranker;
    }

    public ContextSelection Select(ContextBundle bundle, string query)
    {
        var ranked = _ranker.Rank(bundle, query, RankingOptions.Default);

        var dropped = bundle.Items
            .Select(item => item.Id)
            .Except(ranked.Select(r => r.Item.Id))
            .ToArray();

        var decision = new DecisionTrace(
            $"Ranked and selected {ranked.Count} of {bundle.Items.Count} context item(s)",
            "Scored by keyword overlap, trust level and recency decay against the turn input",
            dropped);

        return new ContextSelection(ranked, decision);
    }
}
