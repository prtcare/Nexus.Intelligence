using NexusAI.Application.Providers;
using System.Text;

namespace NexusAI.Application.Chat.Prompting;

public sealed class PromptBuilder : IPromptBuilder
{
    public ChatRequest Build(
        PromptContext context)
    {
        var builder = new StringBuilder();

        if (context.Knowledge.Count > 0)
        {
            builder.AppendLine("Workspace Knowledge");
            builder.AppendLine();

            foreach (var item in context.Knowledge)
            {
                builder.AppendLine($"Title: {item.Title}");
                builder.AppendLine(item.Content);
                builder.AppendLine();
            }
        }

        builder.AppendLine("User Request");
        builder.AppendLine(context.UserPrompt);

        return new ChatRequest
        {
            Prompt = builder.ToString(),
            History = context.History
        };
    }
}