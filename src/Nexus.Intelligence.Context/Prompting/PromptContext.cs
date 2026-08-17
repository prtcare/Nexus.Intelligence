using NexusAI.Domain.ConversationMessage;
using KnowledgeModel = NexusAI.Domain.Knowledge.Knowledge;

namespace NexusAI.Application.Chat.Prompting;

public sealed class PromptContext
{
    public required string UserPrompt { get; init; }

    public required IReadOnlyList<ConversationMessage> History { get; init; }

    public required IReadOnlyList<KnowledgeModel> Knowledge { get; init; }
}