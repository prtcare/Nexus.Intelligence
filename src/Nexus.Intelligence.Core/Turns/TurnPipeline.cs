using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Memory;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

public sealed class TurnPipeline : ITurnPipeline
{
    private readonly IIntentClassifier _intentClassifier;
    private readonly IPolicyGate _policyGate;
    private readonly IContextSelector _contextSelector;
    private readonly IAgentSelector _agentSelector;
    private readonly IModelSelector _modelSelector;
    private readonly IPromptStep _promptStep;
    private readonly IModelStep _modelStep;
    private readonly IToolLoop _toolLoop;
    private readonly IResponseComposer _responseComposer;
    private readonly IToolCatalog _toolCatalog;
    private readonly ITurnTraceStore _traceStore;
    private readonly IMemoryStore _memoryStore;
    private readonly TimeProvider _timeProvider;

    public TurnPipeline(
        IIntentClassifier intentClassifier,
        IPolicyGate policyGate,
        IContextSelector contextSelector,
        IAgentSelector agentSelector,
        IModelSelector modelSelector,
        IPromptStep promptStep,
        IModelStep modelStep,
        IToolLoop toolLoop,
        IResponseComposer responseComposer,
        IToolCatalog toolCatalog,
        ITurnTraceStore traceStore,
        IMemoryStore memoryStore,
        TimeProvider timeProvider)
    {
        _intentClassifier = intentClassifier;
        _policyGate = policyGate;
        _contextSelector = contextSelector;
        _agentSelector = agentSelector;
        _modelSelector = modelSelector;
        _promptStep = promptStep;
        _modelStep = modelStep;
        _toolLoop = toolLoop;
        _responseComposer = responseComposer;
        _toolCatalog = toolCatalog;
        _traceStore = traceStore;
        _memoryStore = memoryStore;
        _timeProvider = timeProvider;
    }

    public async Task<IntelligenceTurnResponse> ExecuteAsync(IntelligenceTurnRequest request, CancellationToken ct = default)
    {
        var existing = await _traceStore.FindByIdempotencyKeyAsync(request.TenantId, request.ProductId, request.IdempotencyKey, ct);

        if (existing is not null)
        {
            return existing.Response;
        }

        var turnId = Guid.NewGuid().ToString("N");
        var decisions = new List<DecisionTrace>();

        var intent = _intentClassifier.Classify(request.Input);
        decisions.Add(intent.Decision);

        var policy = _policyGate.Evaluate(request.Actor, request.Constraints);
        decisions.Add(policy.Decision);

        if (!policy.Verdict.Allowed)
        {
            var refusal = BuildRefusal(turnId, policy.Verdict, decisions);
            await PersistAsync(request, turnId, decisions, refusal, ct);
            return refusal;
        }

        var context = _contextSelector.Select(request.Context, request.Input.Text);
        decisions.Add(context.Decision);

        var agent = _agentSelector.Select(intent.Intent, request.Actor);
        decisions.Add(agent.Decision);

        var model = await _modelSelector.SelectAsync(intent.Intent, request.Constraints, ct);
        decisions.Add(model.Decision);

        var catalogTools = await _toolCatalog.ListAsync(ct);
        var availableTools = catalogTools.Where(tool => policy.Verdict.AllowedTools.Contains(tool.ToolId)).ToArray();

        var prompt = _promptStep.Assemble(request.Input, context.Ranked, model.Model, agent.Agent, availableTools);
        decisions.Add(prompt.Decision);

        var identity = new InvocationIdentity(request.TenantId, request.ProductId, turnId, request.Actor.UserId);

        var invocation = await _modelStep.InvokeAsync(prompt.Prompt, model.Model, availableTools, identity, request.Constraints.MaxCost, ct);
        decisions.Add(invocation.Decision);

        var toolLoop = await _toolLoop.RunAsync(
            invocation.Result, prompt.Prompt, model.Model, availableTools, policy.Verdict, request.Constraints, identity, ct);
        decisions.AddRange(toolLoop.Decisions);

        var totalUsage = Combine(invocation.Result.Usage, toolLoop.AccumulatedUsage);
        var usage = new UsageSummary(totalUsage.TokensIn, totalUsage.TokensOut, totalUsage.EstimatedCost, model.Model.ModelId);

        var composed = _responseComposer.Compose(turnId, toolLoop.FinalResult, context.Ranked, toolLoop.ProposedActions, usage);
        decisions.Add(composed.Decision);

        var response = composed.Response with { Decisions = decisions };

        await PersistAsync(request, turnId, decisions, response, ct);

        return response;
    }

    private async Task PersistAsync(
        IntelligenceTurnRequest request,
        string turnId,
        IReadOnlyList<DecisionTrace> decisions,
        IntelligenceTurnResponse response,
        CancellationToken ct)
    {
        var trace = new TurnTrace
        {
            TurnId = turnId,
            Request = request,
            Decisions = decisions,
            Response = response,
            CreatedAt = _timeProvider.GetUtcNow()
        };

        await _traceStore.AddAsync(trace, ct);

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

            await _memoryStore.AddAsync(record, ct);
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

    private static IntelligenceTurnResponse BuildRefusal(string turnId, PolicyVerdict verdict, IReadOnlyList<DecisionTrace> decisions) =>
        new()
        {
            TurnId = turnId,
            Outcome = TurnOutcomeKind.Refusal,
            Reply = new ReplyPayload(verdict.DenialReason ?? "This request was not permitted.", ReplyFormat.PlainText),
            Decisions = decisions,
            Errors = [new TurnError("policy_denied", verdict.DenialReason ?? "Denied by policy.", null)]
        };

    private static ModelUsage Combine(ModelUsage a, ModelUsage b) =>
        new(a.TokensIn + b.TokensIn, a.TokensOut + b.TokensOut, a.EstimatedCost + b.EstimatedCost);
}
