using System.Collections.Generic;
using Nexus.Intelligence.Agents.Abstractions;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Roles;
using Nexus.Intelligence.Core.Turns;
using Nexus.Intelligence.Memory;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Tests.Turns;

// The W7D live-path harness: the REAL TurnPipeline, composed over the REAL governed path, with the
// turn's own collaborators either real or trivially deterministic.
//
// WHY IT COMPOSES THE LIVE TYPE. Task 12 asks whether a turn issued to the Product-facing pipeline
// reaches a provider through governance, and whether a refused turn reaches one at all. Only the real
// TurnPipeline can answer that: a harness that reimplemented its wiring would test that reimplementation.
// Everything between the envelope and the two egress seams is the code the estate runs.
//
// The two egress seams are the recording ones from GovernedPath, so "zero provider calls" is a count on
// a collaborator that would otherwise have been reached.
//
// The four collaborators that are fakes are the ones with no bearing on the claim: the model catalog
// the role resolver reads, the runtime agent registry the selector does not read, and the platform tool
// catalogue the pipeline narrows from.
internal sealed record LivePathOptions
{
    /// <summary>The governed path's own fixture, including the registry everything reads from.</summary>
    public GovernedPathOptions Governed { get; init; } = new();

    /// <summary>The tool identifiers the Platform catalogue offers. Empty means it offers none.</summary>
    public IReadOnlyList<string> CatalogueToolIds { get; init; } = [];

    /// <summary>
    /// The model an operator assigned to the default AI role, where a test wants an assignment to exist.
    /// Null leaves the role registered with no assignment.
    /// </summary>
    public string? RoleModelId { get; init; }

    /// <summary>The actor's permissions. Non-empty by default, because zero permissions is a policy refusal.</summary>
    public IReadOnlyList<string> ActorPermissions { get; init; } = ["tools:*"];
}

/// <summary>The live pipeline over the governed path, with both egress seams recorded.</summary>
internal sealed class LiveTurnPath
{
    private LiveTurnPath(
        GovernedPath governed,
        TurnPipeline pipeline,
        ITurnTraceStore traces,
        LivePathOptions options)
    {
        Governed = governed;
        Pipeline = pipeline;
        Traces = traces;
        Options = options;
    }

    /// <summary>The governed path the pipeline calls into.</summary>
    public GovernedPath Governed { get; }

    /// <summary>The live pipeline under test.</summary>
    public TurnPipeline Pipeline { get; }

    /// <summary>Where the pipeline persisted its turn traces, for the trace assertions.</summary>
    public ITurnTraceStore Traces { get; }

    /// <summary>The options this path was composed with.</summary>
    public LivePathOptions Options { get; }

    /// <summary>The provider seam. Zero means no provider was ever reached.</summary>
    public RecordingModelStep Model => Governed.Model;

    /// <summary>The tool seam. Zero means no tool was ever executed.</summary>
    public RecordingToolGateway Gateway => Governed.Gateway;

    /// <summary>Composes the live path.</summary>
    public static LiveTurnPath Compose(LivePathOptions options)
    {
        // A turn is refused at the instruction-set stage when its agent names an unregistered prompt, so
        // the fixture registers the conversational default and an agent that names it. Both are ordinary
        // registry entries an operator would write; neither is a test-only affordance.
        var agents = options.Governed.Agents.Count == 0
            ? new[] { GovernedPath.Agent("developer", promptId: AiPrompts.ConversationTurn) }
            : [.. options.Governed.Agents];

        var prompts = options.Governed.Prompts.Count == 0
            ? new[] { GovernedPath.Prompt(AiPrompts.ConversationTurn) }
            : [.. options.Governed.Prompts];

        var governed = GovernedPath.Compose(options.Governed with
        {
            Agents = agents,
            Prompts = prompts,
        });

        var traces = new InMemoryTurnTraceStore();

        // The role store is real and seeded from configuration, because W7D TASK 9 is about what the
        // pipeline does with an operator's assignment. An empty store would prove nothing about it.
        var roles = new InMemoryAiRoleStore(
            seedRoles: [new AiRole(AiRole.DefaultRoleName, "The W7D live-path fixture role.")],
            seedAssignments: options.RoleModelId is { Length: > 0 } assigned
                ?
                [
                    new AiRoleAssignment(
                        AiRole.DefaultRoleName,
                        assigned,
                        ModelCapabilities.Chat | ModelCapabilities.Reasoning,
                        new System.DateTimeOffset(2026, 8, 30, 0, 0, 0, System.TimeSpan.Zero)),
                ]
                : null);

        var pipeline = new TurnPipeline(
            new IntentClassifier(),
            new PolicyGate(),
            new AgentSelector(new NoRuntimeAgents(), governed.Registry),
            governed.Registry,
            new AiRoleResolver(roles, new FixtureModelCatalog(options.RoleModelId)),
            governed.Execution,
            new ResponseComposer(),
            new FixtureToolCatalog(options.CatalogueToolIds),
            traces,
            new InMemoryMemoryStore(System.TimeProvider.System),
            System.TimeProvider.System);

        return new LiveTurnPath(governed, pipeline, traces, options);
    }

    /// <summary>Runs one Product-facing turn through the live pipeline.</summary>
    public Task<IntelligenceTurnResponse> ExecuteAsync(
        IntelligenceTurnRequest request,
        CancellationToken ct = default) => Pipeline.ExecuteAsync(request, ct);

    /// <summary>
    /// One Product-shaped turn request. Everything a test might vary is a parameter; everything else is
    /// stated in the shape a Product would send it.
    /// </summary>
    public static IntelligenceTurnRequest Turn(
        LivePathOptions options,
        string input = "What does the governed path do?",
        TurnInputKind kind = TurnInputKind.UserMessage,
        DataClassification? classification = DataClassification.Internal,
        ContextBundle? context = null,
        IReadOnlyList<string>? allowedTools = null,
        bool requireApprovalForWrites = true,
        string? modelHint = null,
        string idempotencyKey = "idem-w7d-live",
        string? correlationId = "corr-w7d-live") => new()
        {
            TenantId = "tenant-acme",
            ProductId = "nexus-developer",
            Scope = new ScopeRef("workspace", "workspace-main", []),
            Actor = new ActorRef("user-w7d", ["developer"], options.ActorPermissions),
            Input = new TurnInput(kind, input, []),
            Context = context ?? ContextBundle.Empty,
            Constraints = new TurnConstraints
            {
                AllowedTools = allowedTools ?? options.CatalogueToolIds,
                RequireApprovalForWrites = requireApprovalForWrites,
                ModelHint = modelHint,
            },
            Classification = classification,
            IdempotencyKey = idempotencyKey,
            CorrelationId = correlationId,
        };

    /// <summary>True when any recorded trace line contains the fragment.</summary>
    public bool TraceContains(IntelligenceTurnResponse response, string fragment) =>
        response.Decisions.Any(decision =>
            decision.What.Contains(fragment, System.StringComparison.Ordinal)
            || decision.Why.Contains(fragment, System.StringComparison.Ordinal));
}

/// <summary>
/// The runtime agent registry, which holds nothing.
/// </summary>
/// <remarks>
/// <see cref="AgentSelector"/> holds this collaborator and never reads it: a turn's agent identity comes
/// from the AI agent registry, and the runtime registry answers only which dispatcher <em>type</em> would
/// implement an agent. The members therefore throw rather than return a stub, so that if a future edit
/// starts depending on runtime agents the fixture fails loudly instead of quietly answering with nothing.
/// </remarks>
internal sealed class NoRuntimeAgents : IAgentRegistry
{
    public IReadOnlyCollection<IAgent> GetAll() => [];

    public IAgent GetAgent(AgentType type) => throw new System.NotSupportedException(
        $"The W7D live-path fixture holds no runtime agents, and the turn path does not ask for one "
        + $"(requested '{type}').");

    public bool TryGetAgent(AgentType type, out IAgent? agent)
    {
        agent = null;
        return false;
    }
}

/// <summary>The model catalog the role resolver reads, holding only the model an assignment names.</summary>
internal sealed class FixtureModelCatalog : IModelCatalog
{
    private readonly IReadOnlyList<ModelDescriptor> _models;

    public FixtureModelCatalog(string? modelId)
        => _models = modelId is { Length: > 0 }
            ?
            [
                new ModelDescriptor(
                    modelId,
                    "fixture",
                    ModelCapabilities.Chat | ModelCapabilities.Reasoning,
                    128_000,
                    0.002m,
                    0.008m,
                    LatencyClass.Medium),
            ]
            : [];

    public Task<IReadOnlyList<ModelDescriptor>> ListAsync(ModelQuery query, CancellationToken ct = default)
        => Task.FromResult(_models);
}

/// <summary>The Platform tool catalogue, offering the identifiers a test names.</summary>
internal sealed class FixtureToolCatalog : IToolCatalog
{
    private readonly IReadOnlyList<ToolDescriptor> _tools;

    public FixtureToolCatalog(IReadOnlyList<string> toolIds)
        => _tools = [.. toolIds.Select(toolId => GovernedPath.Descriptor(toolId))];

    public Task<IReadOnlyList<ToolDescriptor>> ListAsync(CancellationToken ct = default)
        => Task.FromResult(_tools);
}
