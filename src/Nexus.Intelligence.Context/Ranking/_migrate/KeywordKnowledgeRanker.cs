using KnowledgeModel = NexusAI.Domain.Knowledge.Knowledge;

namespace NexusAI.Application.Knowledge.Services;

public sealed class KeywordKnowledgeRanker : IKnowledgeRanker
{
    public IReadOnlyList<KnowledgeModel> Rank(
        IReadOnlyList<KnowledgeModel> knowledge,
        string query,
        int maxResults = 5)
    {
        var terms = query
            .Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(t => t.ToLowerInvariant())
            .Distinct()
            .ToArray();

        return knowledge
            .Select(item => new
            {
                Item = item,
                Score = terms.Count(term =>
                    item.Title.Contains(term, StringComparison.OrdinalIgnoreCase) ||
                    item.Content.Contains(term, StringComparison.OrdinalIgnoreCase))
            })
            .OrderByDescending(x => x.Score)
            .ThenBy(x => x.Item.Title)
            .Take(maxResults)
            .Select(x => x.Item)
            .ToList();
    }
}