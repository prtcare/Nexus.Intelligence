using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Roles;
using Nexus.Intelligence.Memory;
using Nexus.Platform.Contracts.Core;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

/// <summary>
/// The live conversational pipeline, wired to the governed execution path.
/// </summary>
/// <remarks>
/// <para>
/// <b>What this type no longer does is the substantive change of W7D.</b> It used to select a model
/// itself — from the provider catalogue, through <c>IModelSelector</c>, consulting no governance — then
/// assemble a prompt, then call <c>IModelGateway</c> through two separate seams. Every one of those
/// steps is now inside <see cref="IGovernedTurnExecution"/>, and this type cannot perform them because
/// it holds none of the ports that would let it: there is no model selector, no model step and no tool
/// loop among its dependencies.
/// </para>
/// <para>
/// <b>That is a structural guarantee rather than a convention.</b> The directive says the live pipeline
/// must not choose a provider, choose a model, reach a provider secret or invoke a second legacy routing
/// path. Keeping the ports out of this constructor means a future edit cannot reintroduce any of them
/// without deleting a dependency and adding another — a visible change in a reviewed diff, rather than a
/// line that quietly reappears inside a method.
/// </para>
/// <para>
/// <b>What it still owns is the turn envelope.</b> Classification, identity, execution policy and
/// idempotency are Product-facing concerns, and this is the layer that knows the Product's wire contract
/// and therefore the layer that must state what the envelope could not. It derives each one from the
/// envelope, records that it derived it, and hands the result to the governed path — so the derivation
/// is auditable in the turn trace rather than implicit in a default.
/// </para>
/// </remarks>
public sealed class TurnPipeline : ITurnPipeline
{
    /// <summary>
    /// The capability every conversational turn asks for.
    /// </summary>
    /// <remarks>
    /// A turn has one shape. <c>TurnIntent</c> is not a capability — it says what the caller wants
    /// <em>done with</em> the answer, and it drives agent selection and the response contract. Mapping
    /// intents onto capabilities would be inventing a capability vocabulary per caller need, which is the
    /// opposite of the semantic capability model W7A built: callers ask for a capability, and the
    /// registry decides what serves it.
    /// </remarks>
    private const string TurnCapability = AiCapabilities.ChatComplete;

    private readonly IIntentClassifier _intentClassifier;
    private readonly IPolicyGate _policyGate;
    private readonly IAgentSelector _agentSelector;
    private readonly IAiAgentRegistry _agents;
    private readonly IAiRoleResolver _roleResolver;
    private readonly IGovernedTurnExecution _governedExecution;
    private readonly IResponseComposer _responseComposer;
    private readonly IToolCatalog _toolCatalog;
    private readonly ITurnTraceStore _traceStore;
    private readonly IMemoryStore _memoryStore;
    private readonly TimeProvider _timeProvider;

    /// <summary>Composes the live pipeline over the governed execution path.</summary>
    public TurnPipeline(
        IIntentClassifier intentClassifier,
        IPolicyGate policyGate,
        IAgentSelector agentSelector,
        IAiAgentRegistry agents,
        IAiRoleResolver roleResolver,
        IGovernedTurnExecution governedExecution,
        IResponseComposer responseComposer,
        IToolCatalog toolCatalog,
        ITurnTraceStore traceStore,
        IMemoryStore memoryStore,
        TimeProvider timeProvider)
    {
        ArgumentNullException.ThrowIfNull(intentClassifier);
        ArgumentNullException.ThrowIfNull(policyGate);
        ArgumentNullException.ThrowIfNull(agentSelector);
        ArgumentNullException.ThrowIfNull(agents);
        ArgumentNullException.ThrowIfNull(roleResolver);
        ArgumentNullException.ThrowIfNull(governedExecution);
        ArgumentNullException.ThrowIfNull(responseComposer);
        ArgumentNullException.ThrowIfNull(toolCatalog);
        ArgumentNullException.ThrowIfNull(traceStore);
        ArgumentNullException.ThrowIfNull(memoryStore);
        ArgumentNullException.ThrowIfNull(timeProvider);

        _intentClassifier = intentClassifier;
        _policyGate = policyGate;
        _agentSelector = agentSelector;
        _agents = agents;
        _roleResolver = roleResolver;
        _governedExecution = governedExecution;
        _responseComposer = responseComposer;
        _toolCatalog = toolCatalog;
        _traceStore = traceStore;
        _memoryStore = memoryStore;
        _timeProvider = timeProvider;
    }

    /// <inheritdoc />
    public async Task<IntelligenceTurnResponse> ExecuteAsync(
        IntelligenceTurnRequest request,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        var existing = await _traceStore
            .FindByIdempotencyKeyAsync(request.TenantId, request.ProductId, request.IdempotencyKey, ct)
            .ConfigureAwait(false);

        if (existing is not null)
        {
            return existing.Response;
        }

        var turnId = Guid.NewGuid().ToString("N");
        var decisions = new List<DecisionTrace>();

        var intent = _intentClassifier.Classify(request.Input);
        decisions.Add(intent.Decision);

        // The platform's own gate runs first and still runs. It is deterministic, AI-free, and answers a
        // question governance does not: whether this actor may take this kind of turn at all. The two are
        // not alternatives — an actor refused here never reaches governance, and an actor admitted here
        // is still governed afterwards.
        var policy = _policyGate.Evaluate(request.Actor, request.Constraints);
        decisions.Add(policy.Decision);

        if (!policy.Verdict.Allowed)
        {
            var refusal = BuildRefusal(turnId, policy.Verdict, decisions);
            await PersistAsync(request, turnId, decisions, refusal, ct).ConfigureAwait(false);
            return refusal;
        }

        var agent = _agentSelector.Select(intent.Intent, request.Actor);
        decisions.Add(agent.Decision);

        // The role is resolved and recorded, and its configured model is deliberately not applied. See
        // RecordRoleAsync for why: a role naming a model is precisely the caller-side pin that
        // AiCapabilityRequest exists to make inexpressible. What the assignment does get is an answer —
        // see RecordRoleOutcome, which compares the role's declared expectation against the route the
        // registry actually chose and records the result either way.
        var roleModel = await RecordRoleAsync(decisions, ct).ConfigureAwait(false);

        if (request.Constraints.ModelHint is { Length: > 0 } hint)
        {
            decisions.Add(new DecisionTrace(
                $"Ignored the caller's model hint '{hint}'",
                "A caller states the work, not the route. Model preference is expressed by the registry and "
                + "the router's objective, so a hint from the envelope cannot be honoured without "
                + "reintroducing caller-side model selection.",
                []));
        }

        var offeredTools = await OfferedToolsAsync(policy.Verdict, ct).ConfigureAwait(false);
        var instructionSet = InstructionSetFor(agent.AgentId, decisions);
        var identity = new InvocationIdentity(request.TenantId, request.ProductId, turnId, request.Actor.UserId);

        var outcome = await _governedExecution.ExecuteAsync(
            new GovernedTurnRequest
            {
                RequestId = turnId,
                Purpose = TurnEnvelope.PurposeFor(intent.Intent),
                Capability = CapabilityId.Parse(TurnCapability),
                Requester = TurnEnvelope.RequesterFor(request),
                Input = request.Input,
                Context = request.Context,
                Classification = TurnEnvelope.Classify(request, decisions),
                Execution = TurnEnvelope.ExecutionFor(request.Constraints),
                OfferedToolIds = [.. offeredTools.Select(tool => tool.ToolId)],
                OfferedTools = offeredTools,
                AgentId = agent.AgentId,
                PromptId = instructionSet,
                Identity = identity,
                Constraints = request.Constraints,
                CorrelationId = request.CorrelationId ?? turnId,
                IdempotencyKey = request.IdempotencyKey,
            },
            ct).ConfigureAwait(false);

        decisions.AddRange(outcome.Decisions);

        // The role's answer, recorded after routing rather than in place of it.
        RecordRoleOutcome(roleModel, outcome, decisions);

        if (!outcome.Invoked || outcome.Result is null)
        {
            // A refused turn is a refusal and not a failure. The distinction matters to the Product: a
            // failure is something to retry, and a refusal is something to change the request about. Every
            // refusal that reaches here carries the decision that produced it, so the Product can say
            // which gate fired instead of "AI is unavailable".
            var refused = BuildGovernedRefusal(turnId, outcome, decisions);
            await PersistAsync(request, turnId, decisions, refused, ct, outcome.AuditReference)
                .ConfigureAwait(false);
            return refused;
        }

        var toolLoop = outcome.Tools;
        var totalUsage = toolLoop is null
            ? outcome.Result.Result.Usage
            : Combine(outcome.Result.Result.Usage, toolLoop.AccumulatedUsage);

        // Present by construction: Invoked is true only on the path where routing selected a candidate,
        // because the candidate is the only thing that carries a governance decision to invoke with.
        var usage = new UsageSummary(
            totalUsage.TokensIn,
            totalUsage.TokensOut,
            totalUsage.EstimatedCost,
            outcome.Routing!.Selected!.ModelId);

        var composed = _responseComposer.Compose(
            turnId,
            toolLoop?.FinalResult ?? outcome.Result.Result,
            outcome.Context,
            toolLoop?.ProposedActions ?? [],
            usage);

        decisions.Add(composed.Decision);

        var response = composed.Response with { Decisions = decisions };

        await PersistAsync(request, turnId, decisions, response, ct, outcome.AuditReference)
            .ConfigureAwait(false);

        return response;
    }

    /// <summary>
    /// Resolves the role and records it, without letting it choose a route.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>This is W7D TASK 9, and it is a deliberate departure from the previous behaviour.</b> The role
    /// used to be resolved and its configured model merged into <c>TurnConstraints.ModelHint</c>, which
    /// the model selector then preferred. The role was therefore a model pin by another name, applied
    /// inside the AI Head rather than by the caller — which is worse than a caller pin, because the
    /// caller could not see it and the audit record did not distinguish it from a capability-based choice.
    /// </para>
    /// <para>
    /// <b>The pin is gone and cannot be replaced by a preference, because W7C's router refuses one.</b>
    /// <see cref="AiRoutingContext"/> states its own boundary explicitly: a caller may say how big the
    /// work is and may not say which model should serve it. There is no preference channel to thread the
    /// assignment through, so preserving the pin would mean adding one — and a preference channel is a
    /// pin with softer wording, which is the thing the directive's Task 8 forbids leaving in place. The
    /// two clauses of the directive pull against each other here, and the routing one wins because it is
    /// the security property.
    /// </para>
    /// <para>
    /// <b>The role is still resolved, and that is not vestigial.</b> Resolving it records that a role was
    /// applied, which is what an audit asks. The assignment is still the place an operator states which
    /// model they <em>expect</em> this kind of interaction to use — and <see cref="RecordRoleOutcome"/>
    /// now answers them, by reporting whether the registry's route agreed with the expectation. An
    /// operator who wants the expectation to become the outcome expresses that by giving the model a
    /// priority in the registry, where it is a routing input rather than a bypass.
    /// </para>
    /// <para>
    /// The resolution is advisory, so a role that fails to resolve does not fail the turn. That is the
    /// same posture the previous code took — it fell through to capability selection when the assigned
    /// model was unavailable — and it is the right one: the role is a preference and the turn is the work.
    /// </para>
    /// </remarks>
    /// <returns>The model the role declared, or null where it declared none.</returns>
    private async Task<string?> RecordRoleAsync(List<DecisionTrace> decisions, CancellationToken ct)
    {
        var role = await _roleResolver.ResolveAsync(AiRole.DefaultRoleName, ct).ConfigureAwait(false);

        decisions.Add(role.Decision);

        if (role.Assignment?.ModelId is not { Length: > 0 } assigned)
        {
            return null;
        }

        decisions.Add(new DecisionTrace(
            $"Noted the role's assigned model '{assigned}' without routing to it",
            $"Role '{AiRole.DefaultRoleName}' names a model, and that naming is a recorded expectation "
            + "rather than a route: the registry and the router's configured objective select the model, so "
            + "a role assignment cannot bypass governance or override an operator's routing policy. The "
            + "route the registry chose is reported against this expectation below.",
            []));

        return assigned;
    }

    /// <summary>
    /// Reports the route the registry chose against the model the role declared.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>This is the part of the role's behaviour that survives, and it is worth having.</b> A role
    /// assignment that silently stopped mattering would leave an operator's configuration asserting
    /// something the estate no longer honours, with nothing anywhere saying so. Comparing the two turns
    /// the assignment into a check: either the registry agrees with the role, or the trace says it does
    /// not and names both models.
    /// </para>
    /// <para>
    /// <b>A refusal is a divergence too, and it is recorded as one.</b> Where nothing was routed, the
    /// expectation went unmet for whatever reason the refusal gives — which is the answer an operator
    /// asking "why is my role's model not being used" actually needs, and it is in the same trace as the
    /// refusal that produced it.
    /// </para>
    /// <para>
    /// It runs on both outcomes rather than only on success, because a divergence that is only reported
    /// when it does not matter is not a check.
    /// </para>
    /// </remarks>
    private static void RecordRoleOutcome(
        string? roleModel,
        GovernedTurnOutcome outcome,
        List<DecisionTrace> decisions)
    {
        if (roleModel is null)
        {
            return;
        }

        if (outcome.Routing?.Selected?.ModelId is not { Length: > 0 } routed)
        {
            decisions.Add(new DecisionTrace(
                $"The role's assigned model '{roleModel}' was not reached: nothing was routed",
                $"Role '{AiRole.DefaultRoleName}' expects '{roleModel}', and the execution was refused "
                + $"before a route was selected ({outcome.Decision.RuleId}). The role's expectation is "
                + "unmet for the reason the refusal states, not because the assignment was ignored.",
                [outcome.Decision.RuleId]));

            return;
        }

        var agrees = string.Equals(roleModel, routed, StringComparison.OrdinalIgnoreCase);

        decisions.Add(agrees
            ? new DecisionTrace(
                $"The role's assigned model '{roleModel}' matches the routed model",
                $"Role '{AiRole.DefaultRoleName}' expects '{roleModel}' and the registry routed to it. "
                + "The expectation was met by the routing policy rather than imposed on it.",
                [])
            : new DecisionTrace(
                $"The role's assigned model '{roleModel}' differs from the routed model '{routed}'",
                $"Role '{AiRole.DefaultRoleName}' expects '{roleModel}' and the registry routed to "
                + $"'{routed}'. The role no longer pins the model, so this is a divergence between an "
                + "operator's stated expectation and the routing policy in force — resolved by giving "
                + $"'{roleModel}' a priority in the registry, not by the role overriding the router.",
                [roleModel, routed]));
    }

    /// <summary>
    /// The instruction set the turn runs under: the agent's own where it declares one, and the
    /// conversational default where it does not.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>This is where W7D TASK 2 and TASK 6 meet.</b> The agent registry states which instruction set an
    /// agent operates under, and the prompt registry holds the text at a version. A turn therefore
    /// inherits its instructions from the agent that was selected, and an operator who wants a different
    /// behaviour from an agent changes the agent's <c>PromptId</c> or the prompt's text — a configuration
    /// act with a record — rather than a rebuild.
    /// </para>
    /// <para>
    /// <b>A turn with no registered agent falls back to the conversational default, and that is not
    /// permissive.</b> The default is a registry key like any other: if the estate has not registered it,
    /// the governed path refuses the turn at the instruction-set stage rather than assembling a turn with
    /// no frame. The fallback chooses <em>which key to ask for</em>, never whether the key must exist.
    /// </para>
    /// </remarks>
    private string InstructionSetFor(string agentId, List<DecisionTrace> decisions)
    {
        if (_agents.TryGetAgent(agentId, out var registration) && registration?.PromptId is { Length: > 0 } declared)
        {
            decisions.Add(new DecisionTrace(
                $"Agent '{agentId}' operates under instruction set '{declared}'",
                "Declared by the agent's registry entry. The text is resolved from the prompt registry at "
                + "its approved version, so changing it is a reviewable configuration act.",
                [AiPrompts.ConversationTurn]));

            return declared;
        }

        decisions.Add(new DecisionTrace(
            $"Applied the default instruction set '{AiPrompts.ConversationTurn}'",
            $"Agent '{agentId}' declares no instruction set, so the conversational default was requested. "
            + "Whether it exists and is approved is the prompt registry's and governance's answer.",
            []));

        return AiPrompts.ConversationTurn;
    }

    /// <summary>
    /// Resolves the tools the caller's gate permits, from the platform catalogue.
    /// </summary>
    /// <remarks>
    /// This is the caller-side narrowing and it is not the control. The control is the AI tool registry
    /// and the governance engine, which run afterwards and can only narrow further — an identifier that
    /// survives the policy gate but is absent from the registry is refused as
    /// <see cref="AiGovernanceRules.ToolUnknown"/>, and one whose effect exceeds the profile as
    /// <see cref="AiGovernanceRules.ToolSideEffectExceeded"/>. Two narrowings in sequence cannot widen.
    /// </remarks>
    private async Task<IReadOnlyList<ToolDescriptor>> OfferedToolsAsync(
        PolicyVerdict verdict,
        CancellationToken ct)
    {
        var catalogue = await _toolCatalog.ListAsync(ct).ConfigureAwait(false);

        return
        [
            .. catalogue.Where(tool => verdict.AllowedTools.Contains(tool.ToolId)),
        ];
    }

    private async Task PersistAsync(
        IntelligenceTurnRequest request,
        string turnId,
        IReadOnlyList<DecisionTrace> decisions,
        IntelligenceTurnResponse response,
        CancellationToken ct,
        string? auditReference = null)
    {
        var trace = new TurnTrace
        {
            TurnId = turnId,
            Request = request,
            Decisions = decisions,
            Response = response,

            // W7E TASK 10: the one direction the two histories reference each other. It is null for a
            // turn the platform's own policy gate refused, because that refusal happens before the
            // governed path runs and there is no execution to have evidence about — which is a different
            // fact from a governed execution whose audit record went missing.
            AuditReference = auditReference,
            CreatedAt = _timeProvider.GetUtcNow()
        };

        await _traceStore.AddAsync(trace, ct).ConfigureAwait(false);

        foreach (var hint in response.PersistenceHints)
        {
            var record = new MemoryRecord
            {
                Id = Guid.NewGuid().ToString("N"),
                TenantId = request.TenantId,
                ProductId = request.ProductId,
                Scope = request.Scope,
                Kind = MapMemoryKind(hint.Kind),
                Content = $"{hint.Title}: {hint.Body}",
                Trust = hint.SuggestedTrust,
                CreatedAt = _timeProvider.GetUtcNow(),
                Tags = [hint.Kind.ToString()]
            };

            await _memoryStore.AddAsync(record, ct).ConfigureAwait(false);
        }
    }

    private static MemoryKind MapMemoryKind(PersistenceHintKind kind) => kind switch
    {
        PersistenceHintKind.KnowledgeCandidate => MemoryKind.Fact,
        PersistenceHintKind.DecisionCandidate => MemoryKind.Pattern,
        PersistenceHintKind.MemoryNote => MemoryKind.Preference,
        PersistenceHintKind.ActionCandidate => MemoryKind.Outcome,
        PersistenceHintKind.Summary => MemoryKind.Summary,
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null)
    };

    /// <summary>A refusal from the platform's own policy gate.</summary>
    private static IntelligenceTurnResponse BuildRefusal(
        string turnId,
        PolicyVerdict verdict,
        IReadOnlyList<DecisionTrace> decisions) =>
        new()
        {
            TurnId = turnId,
            Outcome = TurnOutcomeKind.Refusal,
            Reply = new ReplyPayload(verdict.DenialReason ?? "This request was not permitted.", ReplyFormat.PlainText),
            Decisions = decisions,
            Errors = [new TurnError("policy_denied", verdict.DenialReason ?? "Denied by policy.", null)]
        };

    /// <summary>
    /// A refusal from governance, routing or exposure — carrying which of the three refused and why.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>The governance rule identifier is the error code, and it is stable.</b> A Product that has to
    /// show its user something needs a code it can branch on and translate; <c>governance.model.not-approved</c>
    /// and <c>governance.exposure.blocked</c> lead to different remedies — wait for an approval, versus
    /// stop attaching the document — and a single "ai_unavailable" would erase the difference.
    /// </para>
    /// <para>
    /// <b>A human-required decision is reported as a refusal, not as a failure.</b> It is
    /// <see cref="TurnOutcomeKind.Refusal"/> because the request as submitted cannot proceed and a person
    /// must change something; retrying it unchanged will produce the same answer forever.
    /// </para>
    /// </remarks>
    private static IntelligenceTurnResponse BuildGovernedRefusal(
        string turnId,
        GovernedTurnOutcome outcome,
        IReadOnlyList<DecisionTrace> decisions)
    {
        var decision = outcome.Decision;
        var message = decision.Reason;

        return new IntelligenceTurnResponse
        {
            TurnId = turnId,
            Outcome = TurnOutcomeKind.Refusal,
            Reply = new ReplyPayload(message, ReplyFormat.PlainText),
            Decisions = decisions,
            Errors =
            [
                new TurnError(
                    decision.RuleId,
                    message,
                    outcome.Failure?.Remedy ?? outcome.Failure?.Code),
            ],
        };
    }

    private static ModelUsage Combine(ModelUsage a, ModelUsage b) =>
        new(a.TokensIn + b.TokensIn, a.TokensOut + b.TokensOut, a.EstimatedCost + b.EstimatedCost);
}
