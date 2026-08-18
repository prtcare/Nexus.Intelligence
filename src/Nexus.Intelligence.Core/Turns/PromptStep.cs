using System.Text;
using Nexus.Intelligence.Agents.Abstractions;
using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

public sealed class PromptStep : IPromptStep
{
    private readonly IPromptAssembler _assembler;

    public PromptStep(IPromptAssembler assembler)
    {
        _assembler = assembler;
    }

    public PromptStepResult Assemble(
        TurnInput input,
        IReadOnlyList<RankedContextItem> rankedContext,
        ModelDescriptor model,
        IAgent agent,
        IReadOnlyList<ToolDescriptor> availableTools)
    {
        var request = new PromptRequest
        {
            UserInput = input.Text,
            Context = rankedContext,
            ContextWindowTokens = model.ContextWindow,
            SystemFrame = BuildSystemFrame(agent, availableTools)
        };

        var assembled = _assembler.Assemble(request);

        var droppedIds = rankedContext
            .Where(ranked => !assembled.IncludedContextItemIds.Contains(ranked.Item.Id))
            .Select(ranked => ranked.Item.Id)
            .ToArray();

        var decision = new DecisionTrace(
            $"Assembled prompt with {assembled.IncludedContextItemIds.Count} of {rankedContext.Count} ranked context item(s)",
            $"Fit within model '{model.ModelId}' context window of {model.ContextWindow} tokens (~{assembled.EstimatedTokens} tokens used)",
            droppedIds);

        return new PromptStepResult(assembled, decision);
    }

    private static string BuildSystemFrame(IAgent agent, IReadOnlyList<ToolDescriptor> tools)
    {
        var builder = new StringBuilder();

        builder.AppendLine($"You are the {agent.Metadata.Name} agent. {agent.Metadata.Description}");
        builder.AppendLine();
        builder.AppendLine("When you use information from the supplied context, cite it inline as [ctx:<id>].");

        if (tools.Count > 0)
        {
            builder.AppendLine();
            builder.AppendLine("Available tools:");

            foreach (var tool in tools)
            {
                builder.AppendLine($"- {tool.Name} ({tool.ToolId}): {tool.Description}");
            }

            builder.AppendLine("To call a tool, include exactly: [tool:<toolId>]{\"arg\":\"value\"}");
        }

        return builder.ToString();
    }
}
