using System.Text.Json;
using System.Text.RegularExpressions;
using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Core;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

/// <summary>
/// Executes the tool calls a model asked for, through the tool gateway, under a governed continuation.
/// </summary>
/// <remarks>
/// <para>
/// <b>It holds no model gateway, and that is the whole of what W7D changed here.</b> The loop used to
/// re-invoke the model itself after each round of tool results, which put up to <c>MaxIterations</c>
/// provider calls behind a gate that had been passed once. It now calls
/// <see cref="ContinuationInvocation"/>, which the governed path supplies, so every round is a separate
/// governed question.
/// </para>
/// <para>
/// <b>Tool calls are not re-governed per round, and that is deliberate.</b> The tools available to the
/// loop were narrowed by governance before it was entered, and the loop can only call what it was
/// handed — the descriptors arrive as an argument and there is no other source of them. Re-checking each
/// call would be checking an invariant the type system already holds.
/// </para>
/// </remarks>
public sealed partial class ToolLoop : IToolLoop
{
    private const int MaxIterations = 5;

    private readonly IToolGateway _toolGateway;

    /// <summary>Composes the loop over the platform tool gateway.</summary>
    public ToolLoop(IToolGateway toolGateway)
        => _toolGateway = toolGateway ?? throw new ArgumentNullException(nameof(toolGateway));

    /// <inheritdoc />
    public async Task<ToolLoopResult> RunAsync(
        ModelInvocationResult initialResult,
        AssembledPrompt prompt,
        IReadOnlyList<ToolDescriptor> availableTools,
        PolicyVerdict policy,
        TurnConstraints constraints,
        InvocationIdentity identity,
        ContinuationInvocation continueInvocation,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(initialResult);
        ArgumentNullException.ThrowIfNull(prompt);
        ArgumentNullException.ThrowIfNull(availableTools);
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(constraints);
        ArgumentNullException.ThrowIfNull(identity);
        ArgumentNullException.ThrowIfNull(continueInvocation);

        var toolsById = availableTools.ToDictionary(t => t.ToolId);
        var messages = prompt.Messages.ToList();
        var proposedActions = new List<ProposedAction>();
        var invokedToolIds = new List<string>();
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

                // Recorded after the gateway call and not before: a tool whose invocation threw never
                // ran, and an audit record that named it would say the execution used a capability it
                // did not.
                invokedToolIds.Add(call.ToolId);

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

            // The governed path's continuation, not a gateway. Each round is a separate invocation and
            // therefore a separate governance question — see ContinuationInvocation's remarks for the
            // bypass this replaced.
            var continued = await continueInvocation(messages, ct).ConfigureAwait(false);

            decisions.Add(continued.Decision);

            if (!continued.Result.Success)
            {
                // A failed round ends the loop rather than being retried inside it. Retrying here would
                // re-enter a gate the loop does not own, and the caller's latency ceiling covers the
                // whole operation, so an internal retry loop is how a bounded degradation becomes a
                // caller-visible timeout.
                return new ToolLoopResult(continued.Result, proposedActions, usage, decisions)
                {
                    InvokedToolIds = invokedToolIds,
                };
            }

            current = continued.Result;

            usage = Combine(usage, current.Usage);
        }

        return new ToolLoopResult(current, proposedActions, usage, decisions)
        {
            InvokedToolIds = invokedToolIds,
        };
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
