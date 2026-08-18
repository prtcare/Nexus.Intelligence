using System.Text;
using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Context.Prompting;

public sealed class PromptAssembler : IPromptAssembler
{
    private const double CharsPerToken = 4.0;
    private const double ResponseReservationRatio = 0.25;

    private static readonly IReadOnlyList<ContextItemKind> SectionOrder =
    [
        ContextItemKind.Objective,
        ContextItemKind.Constraint,
        ContextItemKind.Decision,
        ContextItemKind.Fact,
        ContextItemKind.Document,
        ContextItemKind.Artifact,
        ContextItemKind.Outcome,
        ContextItemKind.Instruction,
        ContextItemKind.Message
    ];

    public AssembledPrompt Assemble(PromptRequest request)
    {
        var budgetChars = request.ContextWindowTokens * (1.0 - ResponseReservationRatio) * CharsPerToken;

        var includedIds = new HashSet<string>(request.Context.Select(ranked => ranked.Item.Id));
        var ascendingByScore = request.Context.OrderBy(ranked => ranked.Score).ToList();

        var contextText = BuildContextText(request.Context, includedIds);

        var dropIndex = 0;
        while (contextText.Length > budgetChars && dropIndex < ascendingByScore.Count)
        {
            includedIds.Remove(ascendingByScore[dropIndex].Item.Id);
            dropIndex++;
            contextText = BuildContextText(request.Context, includedIds);
        }

        var systemText = BuildSystemMessage(request.SystemFrame, contextText);

        IReadOnlyList<ModelMessage> messages =
        [
            new ModelMessage { Role = ModelRole.System, Content = systemText },
            new ModelMessage { Role = ModelRole.User, Content = request.UserInput }
        ];

        var survivingIds = request.Context
            .Where(ranked => includedIds.Contains(ranked.Item.Id))
            .Select(ranked => ranked.Item.Id)
            .ToList();

        var estimatedTokens = (int)Math.Ceiling(
            (systemText.Length + request.UserInput.Length) / CharsPerToken);

        return new AssembledPrompt(messages, survivingIds, estimatedTokens);
    }

    private static string BuildContextText(
        IReadOnlyList<RankedContextItem> context, HashSet<string> includedIds)
    {
        var builder = new StringBuilder();

        foreach (var kind in SectionOrder)
        {
            var itemsInSection = context
                .Where(ranked => includedIds.Contains(ranked.Item.Id) && ranked.Item.Kind == kind)
                .ToList();

            if (itemsInSection.Count == 0)
            {
                continue;
            }

            builder.AppendLine($"## {kind}");
            builder.AppendLine();

            foreach (var ranked in itemsInSection)
            {
                var item = ranked.Item;

                builder.Append($"[ctx:{item.Id}] ");

                if (!string.IsNullOrWhiteSpace(item.Title))
                {
                    builder.Append(item.Title);
                    builder.Append(": ");
                }

                builder.AppendLine(item.Body);
            }

            builder.AppendLine();
        }

        return builder.ToString();
    }

    private static string BuildSystemMessage(string? systemFrame, string contextText)
    {
        var builder = new StringBuilder();

        if (!string.IsNullOrWhiteSpace(systemFrame))
        {
            builder.AppendLine(systemFrame);
            builder.AppendLine();
        }

        builder.Append(contextText);

        return builder.ToString();
    }
}
