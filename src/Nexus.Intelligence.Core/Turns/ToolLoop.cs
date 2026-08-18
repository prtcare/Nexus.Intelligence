using System.Text.Json;
using System.Text.RegularExpressions;
using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

public sealed partial class ToolLoop : IToolLoop
{
    private const int MaxIterations = 5;

    private readonly IToolGateway _toolGateway;
    private readonly IModelGateway _modelGateway;

    public ToolLoop(IToolGateway toolGateway, IModelGateway modelGateway)
    {
        _toolGateway = toolGateway;
        _modelGateway = modelGateway;
    }

    public async Task<ToolLoopResult> RunAsync(
        ModelInvocationResult initialResult,
        AssembledPrompt prompt,
        ModelDescriptor model,
        IReadOnlyList<ToolDescriptor> availableTools,
        PolicyVerdict policy,
        TurnConstraints constraints,
        InvocationIdentity identity,
        CancellationToken ct = default)
    {
        var toolsById = availableTools.ToDictionary(t => t.ToolId);
        var messages = prompt.Messages.ToList();
        var proposedActions = new List<ProposedAction>();
        var decisions = new List<DecisionTrace>();
        var usage = ModelUsage.Zero;
        var current = initialResult;

        for (var iteration = 0; iteration < MaxIterations; iteration++)
        {
            var calls = ExtractToolCalls(current.Message?.Content);

            if (calls.Count == 0)
            {
                break;
            }

            if (current.Message is not null)
            {
                messages.Add(current.Message);
            }

            var executedAny = false;

            foreach (var call in calls)
            {
                if (!toolsById.TryGetValue(call.ToolId, out var descriptor))
                {
                    decisions.Add(new DecisionTrace(
                        $"Skipped tool call '{call.ToolId}'",
                        "Tool is not in the policy-allowed tool set",
                        policy.AllowedTools));
                    continue;
                }

                var isReadOnly = descriptor.SideEffect is SideEffectClass.None or SideEffectClass.Read;

                if (!isReadOnly && constraints.RequireApprovalForWrites)
                {
                    proposedActions.Add(new ProposedAction
                    {
                        ToolRef = call.ToolId,
                        Arguments = call.Arguments,
                        ApprovalRequired = true,
                        Rationale = $"Side-effect class '{descriptor.SideEffect}' requires approval before execution."
                    });

                    decisions.Add(new DecisionTrace(
                        $"Proposed tool '{call.ToolId}' for approval",
                        $"Side-effect class '{descriptor.SideEffect}' is not read-only and writes require approval",
                        [$"execute '{call.ToolId}' immediately"]));

                    continue;
                }

                var toolResult = await _toolGateway.InvokeAsync(
                    new ToolInvocation { ToolId = call.ToolId, ArgumentsJson = call.ArgumentsJson, Identity = identity },
                    ct);

                messages.Add(new ModelMessage
                {
                    Role = ModelRole.Tool,
                    Content = toolResult.Success ? toolResult.OutputJson ?? string.Empty : toolResult.Error ?? "Tool invocation failed."
                });

                decisions.Add(new DecisionTrace(
                    $"Executed tool '{call.ToolId}'",
                    $"Side-effect class '{descriptor.SideEffect}' is read-only or pre-approved",
                    []));

                executedAny = true;
            }

            if (!executedAny)
            {
                break;
            }

            current = await _modelGateway.InvokeAsync(
                new ModelInvocation { ModelId = model.ModelId, Messages = messages, Tools = availableTools, Identity = identity },
                ct);

            usage = Combine(usage, current.Usage);
        }

        return new ToolLoopResult(current, proposedActions, usage, decisions);
    }

    private static ModelUsage Combine(ModelUsage a, ModelUsage b) =>
        new(a.TokensIn + b.TokensIn, a.TokensOut + b.TokensOut, a.EstimatedCost + b.EstimatedCost);

    private static IReadOnlyList<ToolCallRequest> ExtractToolCalls(string? content)
    {
        if (string.IsNullOrWhiteSpace(content))
        {
            return [];
        }

        var calls = new List<ToolCallRequest>();

        foreach (Match match in ToolCallPattern().Matches(content))
        {
            var json = match.Groups["json"].Value;
            calls.Add(new ToolCallRequest(match.Groups["id"].Value, json, ParseArguments(json)));
        }

        return calls;
    }

    private static IReadOnlyDictionary<string, string> ParseArguments(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var arguments = new Dictionary<string, string>();

            foreach (var property in document.RootElement.EnumerateObject())
            {
                arguments[property.Name] = property.Value.ValueKind == JsonValueKind.String
                    ? property.Value.GetString() ?? string.Empty
                    : property.Value.GetRawText();
            }

            return arguments;
        }
        catch (JsonException)
        {
            return new Dictionary<string, string>();
        }
    }

    // In-band tool-call protocol the model is instructed to use (see PromptStep): [tool:<id>]{flat json}.
    [GeneratedRegex(@"\[tool:(?<id>[A-Za-z0-9_\-.]+)\]\s*(?<json>\{[^{}]*\})")]
    private static partial Regex ToolCallPattern();
}
