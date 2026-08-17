using KnowledgeModel = NexusAI.Domain.Knowledge.Knowledge;

namespace NexusAI.Application.Knowledge.Services;

public interface IKnowledgeRanker
{
    IReadOnlyList<KnowledgeModel> Rank(
        IReadOnlyList<KnowledgeModel> knowledge,
        string query,
        int maxResults = 5);
}