using NexusAI.Application.Providers;

namespace NexusAI.Application.Chat.Prompting;

public interface IPromptBuilder
{
    ChatRequest Build(
        PromptContext context);
}