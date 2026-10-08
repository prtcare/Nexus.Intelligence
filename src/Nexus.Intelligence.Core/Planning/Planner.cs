using System.Text.Json;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Turns;
using Nexus.Platform.Contracts.Core;

namespace Nexus.Intelligence.Core.Planning;

/// <summary>
/// Produces a plan through the governed execution path.
/// </summary>
/// <remarks>
/// <para>
/// <b>W7D TASK 8, disposition SUPERSEDE.</b> This type was the estate's second ungoverned path to a
/// model, and the more dangerous of the two because it was less visible. It held an
/// <c>IModelSelector</c> and an <c>IModelGateway</c>, chose a model from the provider catalogue on its
/// own authority, and called the gateway directly — reachable from
/// <c>POST /intelligence/v1/plans</c> without passing the turn pipeline, AI Governance, the exposure
/// table or the router. Closing the turn pipeline while leaving this open would have left the directive's
/// "there must be one authoritative routing path" unmet in the most literal way: two paths, one governed.
/// </para>
/// <para>
/// <b>It now holds neither selector nor gateway.</b> Its only route to a model is
/// <see cref="IGovernedTurnExecution"/>, so the plan endpoint runs the same sequence a turn does:
/// exposure, then W7B governance, then the W7C router, then the governed invocation. The
/// <c>SchemaInstruction</c> literal that used to live in this file is gone too — the instruction set is
/// registered under <see cref="AiPrompts.PlanDecomposition"/> and resolved at its approved version, so
/// the text that decides the shape of every plan the product produces is now reviewable and changeable
/// without a rebuild.
/// </para>
/// </remarks>
public sealed class Planner : IPlanner
{
    /// <summary>
    /// The capability a plan request asks for.
    /// </summary>
    /// <remarks>
    /// <c>chat.complete</c>, for the same reason a turn is: planning is a completion with a stricter
    /// response contract, and the strictness is expressed by the instruction set and the response
    /// contract rather than by inventing a capability the registry would then have to learn. A capability
    /// identifier is a statement about what a model must be able to do; a JSON output shape is not.
    /// </remarks>
    private const string PlanCapability = AiCapabilities.ChatComplete;

    private readonly IGovernedTurnExecution _execution;
    private readonly ITurnTraceStore _traceStore;
    private readonly TimeProvider _timeProvider;

    /// <summary>Composes the planner over the governed execution path.</summary>
    public Planner(
        IGovernedTurnExecution execution,
        ITurnTraceStore traceStore,
        TimeProvider timeProvider)
    {
        ArgumentNullException.ThrowIfNull(execution);
        ArgumentNullException.ThrowIfNull(traceStore);
        ArgumentNullException.ThrowIfNull(timeProvider);

        _execution = execution;
        _traceStore = traceStore;
        _timeProvider = timeProvider;
    }

    /// <summary>
    /// Produces a plan for the request's objective, or an empty plan where none could be governed.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>A refused plan returns an empty one and records why.</b> That preserves the endpoint's wire
    /// shape — <see cref="PlanPayload"/> has no field for a refusal, and adding one would be a breaking
    /// change to a Product's contract for a lane that is not supposed to make them. The refusal is
    /// written to the turn trace store instead, which is where the estate's explanation endpoint already
    /// reads from, so "why did I get no plan" has an answer that does not require reading a log.
    /// </para>
    /// <para>
    /// An empty plan is also what this endpoint already returned when the gateway failed, so the
    /// observable behaviour on a bad day is unchanged. What changed is that the bad day is now a recorded
    /// governance decision rather than a silent provider error.
    /// </para>
    /// </remarks>
    public async Task<PlanPayload> CreatePlanAsync(
        IntelligenceTurnRequest request,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        var planId = Guid.NewGuid().ToString("N");
        var decisions = new List<DecisionTrace>();

        var outcome = await _execution.ExecuteAsync(
            new GovernedTurnRequest
            {
                RequestId = planId,
                Purpose = TurnEnvelope.PurposeFor(TurnIntent.Planning),
                Capability = CapabilityId.Parse(PlanCapability),
                Requester = TurnEnvelope.RequesterFor(request),
                Input = request.Input,
                Context = request.Context,
                Classification = TurnEnvelope.Classify(request, decisions),
                Execution = TurnEnvelope.ExecutionFor(request.Constraints),
                OfferedToolIds = [],
                OfferedTools = [],
                AgentId = null,
                PromptId = AiPrompts.PlanDecomposition,
                Identity = new InvocationIdentity(
                    request.TenantId,
                    request.ProductId,
                    planId,
                    request.Actor.UserId),
                Constraints = request.Constraints,
                CorrelationId = request.CorrelationId ?? planId,
                IdempotencyKey = request.IdempotencyKey,
            },
            ct).ConfigureAwait(false);

        decisions.AddRange(outcome.Decisions);

        var plan = outcome is { Invoked: true, Result.Result.Message.Content: { Length: > 0 } content }
            ? ParsePlan(content)
            : new PlanPayload([]);

        if (!outcome.Invoked)
        {
            decisions.Add(new DecisionTrace(
                $"Returned an empty plan: {outcome.Decision.RuleId}",
                outcome.Decision.Reason,
                [.. outcome.Decision.RulesApplied]));
        }

        await RecordAsync(request, planId, decisions, ct).ConfigureAwait(false);

        return plan;
    }

    /// <summary>Writes the plan's decisions to the trace store, so a refusal is discoverable.</summary>
    private async Task RecordAsync(
        IntelligenceTurnRequest request,
        string planId,
        IReadOnlyList<DecisionTrace> decisions,
        CancellationToken ct)
    {
        await _traceStore.AddAsync(
            new TurnTrace
            {
                TurnId = planId,
                Request = request,
                Decisions = decisions,
                Response = new IntelligenceTurnResponse
                {
                    TurnId = planId,
                    Outcome = TurnOutcomeKind.Plan,
                    Decisions = decisions,
                },
                CreatedAt = _timeProvider.GetUtcNow(),
            },
            ct).ConfigureAwait(false);
    }

    private static PlanPayload ParsePlan(string content)
    {
        try
        {
            using var document = JsonDocument.Parse(ExtractJsonObject(content));

            if (!document.RootElement.TryGetProperty("steps", out var stepsElement) || stepsElement.ValueKind != JsonValueKind.Array)
            {
                return new PlanPayload([]);
            }

            var steps = stepsElement.EnumerateArray().Select(ParseStep).ToList();
            return new PlanPayload(steps);
        }
        catch (JsonException)
        {
            return new PlanPayload([]);
        }
    }

    private static PlanStep ParseStep(JsonElement element)
    {
        var id = element.TryGetProperty("id", out var idEl) && idEl.ValueKind == JsonValueKind.String
            ? idEl.GetString()!
            : Guid.NewGuid().ToString("N");

        var title = element.TryGetProperty("title", out var titleEl) && titleEl.ValueKind == JsonValueKind.String
            ? titleEl.GetString()!
            : string.Empty;

        var description = element.TryGetProperty("description", out var descEl) && descEl.ValueKind == JsonValueKind.String
            ? descEl.GetString()
            : null;

        var dependsOn = element.TryGetProperty("dependsOn", out var depsEl) && depsEl.ValueKind == JsonValueKind.Array
            ? depsEl.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray()
            : [];

        var acceptanceCriteria = element.TryGetProperty("acceptanceCriteria", out var acEl) && acEl.ValueKind == JsonValueKind.String
            ? acEl.GetString()
            : null;

        return new PlanStep
        {
            Id = id,
            Title = title,
            Description = description,
            DependsOn = dependsOn,
            AcceptanceCriteria = acceptanceCriteria
        };
    }

    private static string ExtractJsonObject(string content)
    {
        var start = content.IndexOf('{');
        var end = content.LastIndexOf('}');
        return start >= 0 && end > start ? content[start..(end + 1)] : content;
    }
}
