using System.Text;
using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

/// <summary>
/// Assembles prompts from a registered instruction frame plus the execution's own facts.
/// </summary>
/// <remarks>
/// <para>
/// <b>The frame is split into two halves, and only one of them is configurable.</b> The operator-authored
/// half arrives as <c>instructionFrame</c> from <see cref="IAiPromptRegistry"/> and is free text. The
/// generated half — the tool list and the in-band call syntax — is produced here and is not
/// configurable.
/// </para>
/// <para>
/// That asymmetry is deliberate. The call syntax <c>[tool:&lt;id&gt;]{"arg":"value"}</c> is the contract
/// three components share: this step writes it, <see cref="ToolLoop"/> parses it with a regular
/// expression, and the response composer parses the citation form alongside it. Those three are coupled
/// by a string, and the coupling is documented by comment in all three. An operator who could edit the
/// syntax from a configuration file could break tool parsing without touching code, and the failure
/// would present as a model that stopped using tools — which is the hardest possible thing to diagnose
/// from the symptom.
/// </para>
/// </remarks>
public sealed class PromptStep : IPromptStep
{
    private readonly IPromptAssembler _assembler;

    /// <summary>Composes the step over a prompt assembler.</summary>
    public PromptStep(IPromptAssembler assembler)
        => _assembler = assembler ?? throw new ArgumentNullException(nameof(assembler));

    /// <inheritdoc />
    public PromptStepResult Assemble(
        TurnInput input,
        IReadOnlyList<RankedContextItem> rankedContext,
        int contextWindowTokens,
        string instructionFrame,
        IReadOnlyList<ToolDescriptor> availableTools)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(rankedContext);
        ArgumentNullException.ThrowIfNull(availableTools);

        var request = new PromptRequest
        {
            UserInput = input.Text,
            Context = rankedContext,
            ContextWindowTokens = contextWindowTokens,
            SystemFrame = BuildSystemFrame(instructionFrame, availableTools),
        };

        var assembled = _assembler.Assemble(request);

        var droppedIds = rankedContext
            .Where(ranked => !assembled.IncludedContextItemIds.Contains(ranked.Item.Id))
            .Select(ranked => ranked.Item.Id)
            .ToArray();

        var decision = new DecisionTrace(
            $"Assembled prompt with {assembled.IncludedContextItemIds.Count} of {rankedContext.Count} ranked context item(s)",
            $"Fit within a context window of {contextWindowTokens} tokens (~{assembled.EstimatedTokens} tokens used)",
            droppedIds);

        return new PromptStepResult(assembled, decision);
    }

    /// <summary>
    /// Composes the system frame: the operator's instruction text, then the generated tool contract.
    /// </summary>
    /// <remarks>
    /// A blank operator frame is permitted and produces only the generated half. That is not a hole: the
    /// frame is resolved from the registry before this point, and an execution that named an instruction
    /// set has already been refused if it was not registered and approved. An execution that named none
    /// has no operator half because nobody wrote one — and inventing a persona here is exactly the
    /// compiled-in behaviour this change removes.
    /// </remarks>
    private static string BuildSystemFrame(string instructionFrame, IReadOnlyList<ToolDescriptor> tools)
    {
        var builder = new StringBuilder();

        if (!string.IsNullOrWhiteSpace(instructionFrame))
        {
            builder.AppendLine(instructionFrame.TrimEnd());
        }

        if (tools.Count > 0)
        {
            if (builder.Length > 0)
            {
                builder.AppendLine();
            }

            builder.AppendLine("Available tools:");

            foreach (var tool in tools)
            {
                builder.AppendLine($"- {tool.Name} ({tool.ToolId}): {tool.Description}");
            }

            // The in-band protocol ToolLoop's ToolCallPattern recognises. Keep the two in step.
            builder.AppendLine("To call a tool, include exactly: [tool:<toolId>]{\"arg\":\"value\"}");
        }

        return builder.ToString();
    }
}
