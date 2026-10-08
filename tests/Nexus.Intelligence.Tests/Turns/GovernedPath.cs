using System.Collections.Generic;
using System.Linq;
using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Registry;
using Nexus.Intelligence.Core.Routing;
using Nexus.Intelligence.Core.Turns;
using Nexus.Platform.Contracts.Core;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Tests.Turns;

// The W7D test harness: a REAL governed path, composed from the real W7B engine, the real W7C router
// and registry, and the real W7D exposure, context, prompt and tool-loop stages.
//
// WHY IT IS REAL RATHER THAN MOCKED. The claims W7D TASK 10-12 have to support are all of the shape
// "X cannot reach a provider". A suite built on stubbed collaborators could prove that the stubs were
// not called, which is a statement about the stubs. Composing the actual path means a refusal observed
// here is the refusal the estate produces, reached through the same gates in the same order.
//
// The only two seams that are fake are the two that leave the process: the model step and the tool
// gateway. They are the instrument rather than the subject - each records every call it receives, so
// "the provider was never called" is a count of zero on a collaborator that would otherwise have been
// reached, and "the tool never executed" is a count of zero on one that succeeds when it is.
//
// WHY THE FIXTURE IS GENEROUS WITH CEILINGS. Model and provider classification ceilings default to
// Secret and the caller's cost ceiling is unstated, so that in a test about the TOOL gate the tool
// gate is the only binding constraint. A fixture that left every gate tight would refuse for a reason
// the test did not name, and the assertion would pass without exercising what it claims to. Each
// guard below therefore tightens exactly one field and names the rule that field produces.
internal sealed record GovernedPathOptions
{
    /// <summary>The capability the execution asks for.</summary>
    public string Capability { get; init; } = AiCapabilities.ChatComplete;

    /// <summary>The tool identifiers the execution offers, which is also what the profile permits.</summary>
    public IReadOnlyList<string> OfferedToolIds { get; init; } = [];

    /// <summary>The tools the AI registry declares.</summary>
    public IReadOnlyList<AiToolConfigurationEntry> Tools { get; init; } = [];

    /// <summary>The agents the AI registry declares.</summary>
    public IReadOnlyList<AiAgentConfigurationEntry> Agents { get; init; } = [];

    /// <summary>The instruction sets the AI registry declares.</summary>
    public IReadOnlyList<AiPromptConfigurationEntry> Prompts { get; init; } = [];

    /// <summary>The dependency declarations the prohibition register holds.</summary>
    public IReadOnlyList<AiDependencyDeclaration> Dependencies { get; init; } = [];

    /// <summary>The model's approval status, by name.</summary>
    public string ModelApproval { get; init; } = "Approved";

    /// <summary>The provider's approval status, by name.</summary>
    public string ProviderApproval { get; init; } = "Approved";

    /// <summary>Whether the provider may receive content over the network.</summary>
    public bool ProviderEgress { get; init; }

    /// <summary>The provider's trust tier, by name.</summary>
    public string ProviderTrust { get; init; } = "Approved";

    /// <summary>The model's classification ceiling, by name. Generous unless a test says otherwise.</summary>
    public string ModelCeiling { get; init; } = "Secret";

    /// <summary>The provider's classification ceiling, by name. Generous unless a test says otherwise.</summary>
    public string ProviderCeiling { get; init; } = "Secret";

    /// <summary>The model's reasoning class, by name.</summary>
    public string ModelReasoning { get; init; } = "High";

    /// <summary>What the recording model step replies with. May contain a call to a tool id, optionally several.</summary>
    public IReadOnlyList<string> Replies { get; init; } = ["Nothing to do."];

    // ---- W7E: the operational plane -------------------------------------------------------------

    /// <summary>The providers the registry declares. Empty means one generous provider.</summary>
    /// <remarks>
    /// A list rather than a single entry because failover is the subject of several W7E tests, and a
    /// failover needs somewhere to fail over to.
    /// </remarks>
    public IReadOnlyList<AiProviderConfigurationEntry> Providers { get; init; } = [];

    /// <summary>The models the registry declares. Empty means one generous model on that provider.</summary>
    public IReadOnlyList<AiModelConfigurationEntry> Models { get; init; } = [];

    /// <summary>
    /// Health states to declare, keyed by provider or by provider-and-model. Anything not named is
    /// declared Available.
    /// </summary>
    /// <remarks>
    /// Additive rather than total: a test that probes one route's health should not have to restate
    /// every other route's, and a fixture that forgot one would make it Unknown — which is not routable,
    /// so the omission would surface as "nothing was eligible" rather than as a missing line.
    /// </remarks>
    public IReadOnlyList<AiHealthConfigurationEntry> Health { get; init; } = [];

    /// <summary>How many alternate routes the estate permits after a primary failure.</summary>
    public int FallbackDepth { get; init; } = 1;

    /// <summary>Model identifiers the recording seam reports as failed when it is asked for them.</summary>
    public IReadOnlyList<string> FailingModels { get; init; } = [];

    /// <summary>
    /// What the recording seam classifies a <see cref="FailingModels"/> failure as, if anything.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Left null by default, and the default is the point.</b> A null here makes the seam behave
    /// exactly as every adapter behaved before the classification existed: <c>Success</c> false,
    /// provider text in <c>Error</c>, and no typed channel. Every W7E and W7G fixture therefore
    /// exercises the unclassified path unchanged, and the tests that were written against it keep
    /// asserting what they always asserted.
    /// </para>
    /// <para>
    /// Setting it makes the seam a producer of the W7G.1 classification, which is what a test needs in
    /// order to say anything about how a typed provider failure travels. Naming it here rather than
    /// letting a test reach past the fixture keeps the seam the single place a failure is produced.
    /// </para>
    /// </remarks>
    public ModelFailureKind? FailingClassification { get; init; }

    /// <summary>What the recording seam reports the provider consumed. Zero unless a test prices a call.</summary>
    /// <remarks>
    /// The seam reports it as the provider's own measurement, because that is what a real
    /// <c>ModelInvocationResult</c> carries. A test that asserts a cost total needs a non-zero
    /// measurement here; a test that does not leaves it at zero so the cost dimension stays inert.
    /// </remarks>
    public int TokensIn { get; init; }

    /// <summary>Output tokens the recording seam reports.</summary>
    public int TokensOut { get; init; }

    /// <summary>The reliability thresholds. Null means the shipped policy.</summary>
    public AiReliabilityPolicy? Reliability { get; init; }

    /// <summary>The recovery model. Null means the shipped policy, which is what production composes.</summary>
    /// <remarks>
    /// Deliberately the shipped policy rather than <see cref="AiCircuitPolicy.NotEvaluated"/>. A fixture
    /// whose recovery model is switched off is a fixture that cannot observe the behaviour most likely to
    /// change, and the W7E assertions it would keep green are exactly the ones whose meaning this lane
    /// moved.
    /// </remarks>
    public AiCircuitPolicy? Circuit { get; init; }

    /// <summary>The operational budget policy. Null means the gate is not evaluated.</summary>
    /// <remarks>
    /// Off by default so that the W7D suite keeps testing what it names. The fixture's models are
    /// unpriced, so the budget gate would have nothing to compare and would refuse for coverage — which
    /// is a refusal under test in the W7E cost tests and noise in every other one.
    /// </remarks>
    public AiOperationsBudgetPolicy? Budget { get; init; }

    /// <summary>Observed reliability to seed before the execution runs.</summary>
    public IReadOnlyList<AiReliabilityAttempt> History { get; init; } = [];

    /// <summary>
    /// The clock every time-reading part of the composed estate is built on.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>System time by default, so no existing test changes behaviour by omission.</b> A test that
    /// asserts nothing about elapsed time has no reason to care which clock it reads, and leaving this
    /// unstated keeps every one of them exactly as it was.
    /// </para>
    /// <para>
    /// <b>It exists because a test that mixes two clocks cannot be deterministic.</b> Seeded history
    /// stamped from <c>DateTimeOffset.UtcNow</c> and an estate reading <see cref="TimeProvider.System"/>
    /// agree only if the machine happens to route quickly — so a circuit-cooldown assertion written that
    /// way passes or fails on how long the preceding lines took to JIT. Supplying one clock for both the
    /// seeded attempts and the routing decision replaces that race with a difference the test chooses.
    /// W7G.2 F-6.
    /// </para>
    /// </remarks>
    public TimeProvider Time { get; init; } = TimeProvider.System;
}

/// <summary>A composed governed path, with the two egress seams and the operational plane recorded.</summary>
internal sealed class GovernedPath
{
    private GovernedPath(
        GovernedPathOptions options,
        ConfiguredAiRegistry registry,
        IGovernedTurnExecution execution,
        RecordingModelStep model,
        RecordingToolGateway gateway,
        InMemoryAiOperationsLedger ledger,
        InMemoryAiAuditSink audit,
        InMemoryAiReliabilityHistory reliability,
        IAiHealthSnapshotStore health,
        AiOperationsRecorder recorder,
        CountingAiExecutionIdSource executionIds,
        IAiOperationsReadModel operations)
    {
        Options = options;
        Registry = registry;
        Execution = execution;
        Model = model;
        Gateway = gateway;
        Ledger = ledger;
        Audit = audit;
        Reliability = reliability;
        Health = health;
        Recorder = recorder;
        ExecutionIds = executionIds;
        Operations = operations;
    }

    /// <summary>The options this path was composed from, so a helper can build a matching request.</summary>
    public GovernedPathOptions Options { get; }

    /// <summary>The registry everything below reads from.</summary>
    public ConfiguredAiRegistry Registry { get; }

    /// <summary>The governed path under test.</summary>
    public IGovernedTurnExecution Execution { get; }

    /// <summary>The provider seam, recording every invocation it receives.</summary>
    public RecordingModelStep Model { get; }

    /// <summary>The tool seam, recording every invocation it receives.</summary>
    public RecordingToolGateway Gateway { get; }

    /// <summary>The usage and cost ledger the executions write to.</summary>
    public InMemoryAiOperationsLedger Ledger { get; }

    /// <summary>The audit sink the executions write to.</summary>
    public InMemoryAiAuditSink Audit { get; }

    /// <summary>The reliability history the executions write to and the gates read.</summary>
    public InMemoryAiReliabilityHistory Reliability { get; }

    /// <summary>The live health snapshot the router reads.</summary>
    public IAiHealthSnapshotStore Health { get; }

    /// <summary>The recorder, exposed so a test can assert on what one call wrote.</summary>
    public AiOperationsRecorder Recorder { get; }

    /// <summary>
    /// The execution-identity source this path mints from, so a test can name the identity it expects.
    /// </summary>
    /// <remarks>
    /// A known sequence rather than the shipped GUID source, for the reason
    /// <see cref="CountingAiExecutionIdSource"/> gives: a W7F identity test has to assert the value the
    /// estate wrote, and it can only do that if the value is one this harness chose.
    /// </remarks>
    public CountingAiExecutionIdSource ExecutionIds { get; }

    /// <summary>The operations read surface, over the three stores above.</summary>
    public IAiOperationsReadModel Operations { get; }

    /// <summary>
    /// Composes a governed path over the registry the options describe.
    /// </summary>
    /// <remarks>
    /// <b>Real W7E collaborators, not doubles.</b> The ledger, the audit sink, the reliability history,
    /// the price catalogue, the budget evaluator, the operational gate, the failover selector and the
    /// recorder are all the estate's own implementations. That is what makes "the usage was recorded
    /// once" and "the fallback did not bypass governance" statements about the system rather than about
    /// a test's stand-in for it — and the only seams that remain fake are the two that leave the
    /// process.
    /// </remarks>
    public static GovernedPath Compose(GovernedPathOptions options)
    {
        var configuration = Configuration(options);

        // One clock for the whole composition. Reading `TimeProvider.System` here while a caller seeded
        // its history from `DateTimeOffset.UtcNow` is the two-clock defect F-6 records: the parts agree
        // only by luck, and the luck runs out on a cold JIT.
        var time = options.Time;

        var registry = new ConfiguredAiRegistry(configuration);
        var model = new RecordingModelStep(
            options.Replies,
            options.FailingModels,
            new ModelUsage(options.TokensIn, options.TokensOut, 0m),
            options.FailingClassification);
        var gateway = new RecordingToolGateway();
        var policy = Policy(registry, options);
        var evaluator = new DeterministicAiGovernanceEvaluator(policy);
        var health = new InMemoryAiHealthSnapshotStore(
            SeededAiHealthSnapshot.From(configuration, time.GetUtcNow()));
        var ledger = new InMemoryAiOperationsLedger();
        var audit = new InMemoryAiAuditSink();
        var reliability = new InMemoryAiReliabilityHistory(time);

        foreach (var attempt in options.History)
        {
            reliability.Record(attempt);
        }

        var prices = new ConfiguredAiPriceCatalogue(registry);
        var budgetPolicy = options.Budget ?? AiOperationsBudgetPolicy.NotEvaluated;
        var reliabilityPolicy = options.Reliability ?? AiReliabilityPolicy.Default;
        var circuitPolicy = options.Circuit ?? AiCircuitPolicy.Default;

        var operational = new GovernedAiOperationalEligibility(
            prices,
            new ConfiguredAiBudgetEvaluator(budgetPolicy, ledger),
            reliability,
            reliabilityPolicy,
            new ReplayedAiCircuitBreaker(reliability, reliabilityPolicy, circuitPolicy),
            circuitPolicy);

        // One health source, read by both the router and the selector. Two would be two reads of one
        // store taken at two instants, and the second is the one an operator never sees.
        var healthSource = new SnapshotAiHealthSource(health);

        // The evidence store is its own InMemory implementation rather than the audit sink. The sink is
        // the write-only audit port; the evidence store is the record of routing and failover. One
        // object serving both would make the audit read surface answer routing questions it holds no
        // field for, and would let a change to one record's shape silently change the other's.
        var evidence = new InMemoryAiExecutionEvidenceStore();

        var recorder = new AiOperationsRecorder(
            ledger,
            prices,
            reliability,
            evidence,
            new AiAuditEmitter(audit));

        // A known sequence rather than the production GUID source, so a test can assert the identity the
        // governed path actually wrote rather than only that two of them differed.
        var executionIds = new CountingAiExecutionIdSource();

        var routing = AiRoutingPolicy.Default with { FallbackDepth = options.FallbackDepth };

        var execution = new GovernedTurnExecution(
            new GovernedCapabilityRouter(
                registry,
                registry,
                healthSource,
                evaluator,
                operational,
                routing,
                time),
            evaluator,
            new DeclaredClassificationExposureEvaluator(policy.Exposure),
            policy.Exposure,
            new FilteringContextBuilder(),
            new RedactingContextRedactor(),
            new ContextSelector(new KeywordContextRanker(time)),
            registry,
            registry,
            new PromptStep(new PromptAssembler()),
            model,
            new ToolLoop(gateway),
            new GovernedAiFailoverSelector(operational, healthSource, registry, registry),
            recorder,
            executionIds,
            time);

        return new GovernedPath(
            options,
            registry,
            execution,
            model,
            gateway,
            ledger,
            audit,
            reliability,
            health,
            recorder,
            executionIds,
            new AiOperationsReadModel(audit, ledger, ledger, evidence));
    }

    /// <summary>Runs one turn through the composed path.</summary>
    public Task<GovernedTurnOutcome> ExecuteAsync(GovernedTurnRequest request, CancellationToken ct = default)
        => Execution.ExecuteAsync(request, ct);

    // ---------------------------------------------------------------------------------------------
    // Request builders.
    // ---------------------------------------------------------------------------------------------

    /// <summary>One turn request, with every fact a test might want to vary exposed as a parameter.</summary>
    public static GovernedTurnRequest Turn(
        GovernedPathOptions options,
        DataClassification classification = DataClassification.Internal,
        ContextBundle? context = null,
        IReadOnlyList<string>? offeredToolIds = null,
        IReadOnlyList<ToolDescriptor>? offeredTools = null,
        string? agentId = null,
        string? promptId = null,
        AiRequesterIdentity? requester = null,
        TurnConstraints? constraints = null,
        string input = "review this",
        string requestId = "req-w7d") => new()
        {
            RequestId = requestId,
            Purpose = "Exercise the W7D governed path.",
            Capability = CapabilityId.Parse(options.Capability),
            Requester = requester ?? Requester(),
            Input = new TurnInput(TurnInputKind.Task, input, []),
            Context = context ?? ContextBundle.Empty,
            Classification = classification,
            Execution = AiExecutionPolicy.Default,
            OfferedToolIds = offeredToolIds ?? options.OfferedToolIds,
            OfferedTools = offeredTools ?? [.. (offeredToolIds ?? options.OfferedToolIds).Select(id => Descriptor(id))],
            AgentId = agentId,
            PromptId = promptId,
            Identity = new InvocationIdentity("tenant-acme", "nexus-developer", requestId, "user-w7d"),
            Constraints = constraints ?? TurnConstraints.Default,
            CorrelationId = "corr-w7d",
            IdempotencyKey = "idem-w7d",
        };

    /// <summary>
    /// A Product-shaped requester. The data scope is declared by default, because the scope gate is a
    /// subject of one test and an accidental subject of the rest.
    /// </summary>
    public static AiRequesterIdentity Requester(
        IReadOnlyList<string>? dataScopes = null,
        bool mayCauseSideEffects = false,
        bool requiresHumanApprovalForSideEffects = true,
        IReadOnlyList<string>? permissions = null) => new()
        {
            Head = CallingHead.Product,
            ProductId = "nexus-developer",
            TenantId = "tenant-acme",
            WorkspaceId = "workspace-main",
            PrincipalId = "user-w7d",
            PermissionScope = new AiPermissionScope
            {
                Permissions = permissions ?? [],
                MayCauseSideEffects = mayCauseSideEffects,
                RequiresHumanApprovalForSideEffects = requiresHumanApprovalForSideEffects,
            },
            DataScopes = dataScopes ?? ["tenant:acme"],
        };

    /// <summary>One context item, classified where a test cares and unclassified where it does not.</summary>
    public static ContextItem Item(
        string id,
        string body,
        DataClassification? classification = null,
        ContextItemKind kind = ContextItemKind.Document,
        string? title = null,
        IReadOnlyDictionary<string, string>? tags = null) => new()
        {
            Id = id,
            Kind = kind,
            Title = title ?? id,
            Body = body,
            Trust = TrustLevel.Curated,
            Classification = classification,
            Tags = tags ?? new Dictionary<string, string>(),
        };

    /// <summary>A context bundle from items.</summary>
    public static ContextBundle Context(params ContextItem[] items) => new(items);

    /// <summary>A tool descriptor shaped like one the Platform catalogue would supply.</summary>
    public static ToolDescriptor Descriptor(string toolId, SideEffectClass sideEffect = SideEffectClass.Read) => new()
    {
        ToolId = toolId,
        Name = toolId,
        Description = $"The '{toolId}' tool, as the Platform catalogue states it.",
        SideEffect = sideEffect,
    };

    // ---------------------------------------------------------------------------------------------
    // Registry configuration builders.
    // ---------------------------------------------------------------------------------------------

    /// <summary>One tool, as the AI registry declares it.</summary>
    public static AiToolConfigurationEntry Tool(
        string toolId,
        string sideEffect = "Read",
        bool enabled = true,
        string governanceState = "Approved",
        bool requiresHumanApproval = false,
        string maxClassification = "Public") => new()
        {
            ToolId = toolId,
            DisplayName = toolId,
            Purpose = $"The '{toolId}' tool, as W7D declares it.",
            SideEffect = sideEffect,
            RequiresHumanApproval = requiresHumanApproval,
            MaxClassification = maxClassification,
            Enabled = enabled,
            GovernanceState = governanceState,
            DataScope = null,
            Rationale = "W7D test fixture.",
        };

    /// <summary>One agent, as the AI registry declares it.</summary>
    public static AiAgentConfigurationEntry Agent(
        string agentId,
        string? maxSideEffect = "Read",
        string approval = "Approved",
        bool enabled = true,
        IReadOnlyList<string>? allowedCapabilities = null,
        IReadOnlyList<string>? allowedToolIds = null,
        string? promptId = null) => new()
        {
            AgentId = agentId,
            DisplayName = agentId,
            Purpose = $"The '{agentId}' agent, as W7D declares it.",
            AllowedCapabilities = [.. allowedCapabilities ?? [AiCapabilities.ChatComplete]],
            AllowedToolIds = [.. allowedToolIds ?? []],
            MaxClassification = "Secret",
            PromptId = promptId,
            MaxSideEffect = maxSideEffect,
            Enabled = enabled,
            Approval = approval,
            ApprovedBy = approval == "Approved" ? "test-owner" : null,
            GovernanceRationale = "W7D test fixture.",
        };

    /// <summary>One instruction set, as the AI registry declares it.</summary>
    public static AiPromptConfigurationEntry Prompt(
        string promptId,
        string version = "1.0.0",
        string approval = "Approved",
        bool enabled = true,
        string systemFrame = "You are a governed assistant.") => new()
        {
            PromptId = promptId,
            Version = version,
            Owner = "test-owner",
            Purpose = "W7D test fixture.",
            SystemFrame = systemFrame,
            Enabled = enabled,
            Approval = approval,
            Rationale = "W7D test fixture.",
        };

    /// <summary>An AI-prohibited declaration naming a capability.</summary>
    /// <remarks>
    /// Both identifier fields are populated, and they are not redundant. <c>FeatureId</c> is the
    /// declaration's own key in the register; <c>Capability</c> is what makes it a capability-shaped
    /// prohibition, which is the shape <c>IsCapabilityProhibited</c> reads. A declaration carrying only
    /// the first is a prohibition on a feature, and the evaluation asks about the capability.
    /// </remarks>
    public static AiDependencyDeclaration Prohibited(string capability) => new()
    {
        FeatureId = capability,
        Capability = CapabilityId.Parse(capability),
        Owner = "test-owner",
        DependencyClass = AiDependencyClass.AiProhibited,
        Rationale = "W7D test fixture: this capability has no AI path.",
        ProhibitedSurface = AiProhibitedSurface.ProhibitedProductCapability,
    };

    // ---------------------------------------------------------------------------------------------
    // Composition.
    // ---------------------------------------------------------------------------------------------

    private static AiRegistryConfiguration Configuration(GovernedPathOptions options)
    {
        // A fixture that names no providers gets the one generous provider W7D's tests are written
        // against; a fixture that names its own gets exactly those, and its single default model lands
        // on the first of them. That keeps every W7D test unchanged while letting a W7E failover test
        // declare the two routes a failover needs.
        List<AiProviderConfigurationEntry> providers = options.Providers.Count == 0
            ? [DefaultProvider(options)]
            : [.. options.Providers];

        List<AiModelConfigurationEntry> models = options.Models.Count == 0
            ? [DefaultModel(options, providers[0].ProviderId ?? ProviderId)]
            : [.. options.Models];

        return new AiRegistryConfiguration
        {
            Provenance = "W7D test fixture.",
            Routing = new AiRoutingConfigurationEntry
            {
                Objective = "Balanced",
                FallbackDepth = options.FallbackDepth,
            },
            Providers = providers,
            Models = models,
            Health = HealthFor(providers, models, options.Health),
            Agents = [.. options.Agents],
            Tools = [.. options.Tools],
            Prompts = [.. options.Prompts],
        };
    }

    /// <summary>One provider, as W7E declares it. Generous unless a parameter says otherwise.</summary>
    /// <remarks>
    /// <c>SecretReference</c> is the approved reference NAME and never a value. No test in this suite
    /// has a credential to give, and TASK 13 forbids any test from needing one.
    /// </remarks>
    public static AiProviderConfigurationEntry ProviderEntry(
        string providerId,
        string adapterIdentity = "Nexus.Intelligence.Tests.Adapter",
        IReadOnlyList<string>? capabilities = null,
        bool enabled = true,
        bool permitsRemoteEgress = false,
        string trust = "Approved",
        int priority = 10,
        double weight = 1.0,
        string approval = "Approved",
        string maxClassification = "Secret") => new()
        {
            ProviderId = providerId,
            DisplayName = providerId,
            AdapterIdentity = adapterIdentity,
            Capabilities = [.. capabilities ?? [AiCapabilities.ChatComplete]],
            Enabled = enabled,
            SecretReference = "NEXUS_TEST_API_KEY",
            PermitsRemoteEgress = permitsRemoteEgress,
            Trust = trust,
            Priority = priority,
            Weight = weight,
            Approval = approval,
            MaxClassification = maxClassification,
            ApprovedBy = approval == "Approved" ? "test-owner" : null,
            GovernanceRationale = "W7D test fixture.",
        };

    /// <summary>One model, as W7E declares it. Generous unless a parameter says otherwise.</summary>
    /// <remarks>
    /// The rates are optional and absent by default, so a fixture that does not price its model stays
    /// unpriced and the cost gate stays inert — see <see cref="GovernedPathOptions.Budget"/>.
    /// </remarks>
    public static AiModelConfigurationEntry ModelEntry(
        string modelId,
        string providerId,
        IReadOnlyList<string>? capabilities = null,
        string reasoning = "High",
        string availability = "Available",
        bool enabled = true,
        string approval = "Approved",
        string maxClassification = "Secret",
        decimal? inputCostPer1kTokens = null,
        decimal? outputCostPer1kTokens = null,
        string? costCurrency = null,
        string? priceStatus = null,
        IReadOnlyList<string>? processingTiers = null) => new()
        {
            ModelId = modelId,
            ProviderId = providerId,
            DisplayName = modelId,
            Capabilities = [.. capabilities ?? [AiCapabilities.ChatComplete]],
            MaxContextTokens = 200_000,
            MaxOutputTokens = 8_192,
            InputModalities = ["Text"],
            OutputModalities = ["Text"],
            Reasoning = reasoning,
            RelativeSpeed = "Normal",
            Availability = availability,
            Enabled = enabled,
            InputCostPer1kTokens = inputCostPer1kTokens,
            OutputCostPer1kTokens = outputCostPer1kTokens,
            CostCurrency = costCurrency,
            CostMetadataReference = inputCostPer1kTokens is null ? null : "W7E test fixture.",
            PriceStatus = priceStatus,
            ProcessingTiers = [.. processingTiers ?? []],
            Approval = approval,
            MaxClassification = maxClassification,
            ApprovedBy = approval == "Approved" ? "test-owner" : null,
            GovernanceRationale = "W7D test fixture.",
        };

    // The two defaults carry the W7D option knobs, which the parameterised helpers above deliberately
    // do not: a test naming its own providers is describing its own estate, and having the fixture's
    // single-provider fields leak into that description would make a two-provider fixture quietly
    // inherit one provider's ceilings.
    private static AiProviderConfigurationEntry DefaultProvider(GovernedPathOptions options)
        => ProviderEntry(
            ProviderId,
            capabilities: [options.Capability],
            permitsRemoteEgress: options.ProviderEgress,
            trust: options.ProviderTrust,
            approval: options.ProviderApproval,
            maxClassification: options.ProviderCeiling);

    private static AiModelConfigurationEntry DefaultModel(GovernedPathOptions options, string providerId)
        => ModelEntry(
            ModelId,
            providerId,
            capabilities: [options.Capability],
            reasoning: options.ModelReasoning,
            approval: options.ModelApproval,
            maxClassification: options.ModelCeiling);

    /// <summary>
    /// A health row for every declared provider and every declared model, at Available, with the
    /// caller's rows overriding the state of whatever they name.
    /// </summary>
    /// <remarks>
    /// Both kinds of row are needed and neither falls back to the other: a model's health does not
    /// inherit its provider's, and an unstated health is Unknown, which is not routable. Defaulting to
    /// Available is what keeps every W7D fixture routing; declaring a state is what a W7E health test
    /// does to one route.
    /// </remarks>
    private static List<AiHealthConfigurationEntry> HealthFor(
        IReadOnlyList<AiProviderConfigurationEntry> providers,
        IReadOnlyList<AiModelConfigurationEntry> models,
        IReadOnlyList<AiHealthConfigurationEntry> declared)
    {
        var rows = new List<AiHealthConfigurationEntry>();

        foreach (var provider in providers)
        {
            var providerId = provider.ProviderId ?? string.Empty;

            rows.Add(new AiHealthConfigurationEntry
            {
                ProviderId = providerId,
                State = DeclaredHealth(declared, providerId, null) ?? "Available",
            });
        }

        foreach (var model in models)
        {
            var providerId = model.ProviderId ?? string.Empty;
            var modelId = model.ModelId ?? string.Empty;

            rows.Add(new AiHealthConfigurationEntry
            {
                ProviderId = providerId,
                ModelId = modelId,
                State = DeclaredHealth(declared, providerId, modelId) ?? "Available",
            });
        }

        return rows;
    }

    private static string? DeclaredHealth(
        IReadOnlyList<AiHealthConfigurationEntry> declared, string providerId, string? modelId)
        => declared
            .FirstOrDefault(entry =>
                string.Equals(entry.ProviderId, providerId, StringComparison.Ordinal)
                && string.Equals(entry.ModelId, modelId, StringComparison.Ordinal))
            ?.State;

    /// <summary>One health row, for a fixture declaring what it expects the sweep to have published.</summary>
    public static AiHealthConfigurationEntry HealthRow(
        string providerId, string state, string? modelId = null) => new()
        {
            ProviderId = providerId,
            ModelId = modelId,
            State = state,
        };

    private static AiGovernancePolicy Policy(ConfiguredAiRegistry registry, GovernedPathOptions options) => new()
    {
        Dependencies = options.Dependencies.Count == 0
            ? AiDependencyRegistry.Empty
            : new AiDependencyRegistry(options.Dependencies),
        Capabilities = AiCapabilityRegister.Bootstrap(),
        Exposure = DataExposurePolicy.Default(),
        Register = new RegistryAiGovernanceRegister(registry, registry, registry, registry),

        // No budget rules. The models in this fixture are unpriced, so no estimate exists and the cost
        // dimension is inert; leaving the coverage requirement on would refuse a priced route for a
        // reason these tests do not examine and would hide the gate under test behind a different one.
        Budgets = [],
        RequireBudgetRuleForPricedExecution = false,

        // Projected from the registry, which is the whole point of Task 3: the policy table and the
        // tool registry cannot describe the same tool differently because there is one source.
        Tools = registry.GovernanceRules,
        Escalations = [],
    };

    private const string ProviderId = "prov-w7d";
    private const string ModelId = "prov-w7d:model-a";
}

/// <summary>The provider seam, recording every invocation it is asked to make.</summary>
/// <remarks>
/// The only seam besides the tool gateway that is fake, and it is the instrument rather than the
/// subject: every call it receives is recorded, so "the provider was never reached" is a count of zero
/// on a collaborator that would otherwise have been called. It fails for a model named in
/// <c>FailingModels</c> and succeeds for every other one, which is what lets a W7E failover test break
/// exactly one route.
/// </remarks>
internal sealed class RecordingModelStep : IModelStep
{
    private readonly IReadOnlyList<string> _replies;
    private readonly HashSet<string> _failing;
    private readonly ModelUsage _usage;

    /// <summary>The classification this seam puts on a failure it was told to produce, if any.</summary>
    private readonly ModelFailureKind? _failingClassification;
    public RecordingModelStep(
        IReadOnlyList<string> replies,
        IReadOnlyList<string>? failingModels = null,
        ModelUsage? usage = null,
        ModelFailureKind? failingClassification = null)
    {
        _replies = replies.Count == 0 ? ["Nothing to do."] : replies;
        _failing = [.. failingModels ?? []];
        _usage = usage ?? ModelUsage.Zero;
        _failingClassification = failingClassification;
    }

    /// <summary>Every invocation received, in order. Empty means the model was never reached.</summary>
    public List<RecordedModelInvocation> Invocations { get; } = [];

    /// <summary>How many times the model was reached. Zero is the assertion the refusals rely on.</summary>
    public int Count => Invocations.Count;

    /// <summary>The model identifiers that were asked, in order. The failover ordering assertion.</summary>
    public IReadOnlyList<string> ModelsAsked => [.. Invocations.Select(invocation => invocation.ModelId)];

    /// <summary>The text of every message the path sent to a provider, concatenated.</summary>
    public string SentText => string.Join(
        "\n",
        Invocations.SelectMany(invocation => invocation.Prompt.Messages).Select(message => message.Content));

    public Task<ModelStepResult> InvokeAsync(
        AssembledPrompt prompt,
        string modelId,
        IReadOnlyList<ToolDescriptor> tools,
        InvocationIdentity identity,
        decimal? maxCost,
        CancellationToken ct = default)
    {
        Invocations.Add(new RecordedModelInvocation(modelId, prompt, tools));

        if (_failing.Contains(modelId))
        {
            // A failure the provider reports about itself rather than one the seam invents: Success is
            // false and the error text is the provider's own. The path is expected to treat this as an
            // unsuccessful invocation, not as a governance refusal, and the distinction is what the
            // failover tests depend on.
            return Task.FromResult(new ModelStepResult(
                new ModelInvocationResult
                {
                    Success = false,
                    Error = $"The recording seam fails '{modelId}' by request.",

                    // W7G.1 Gate 7: what the provider seam classified the failure as. Null unless the
                    // fixture asked for a classification, so the default is the pre-classification
                    // producer that every other W7E and W7G test was written against.
                    Failure = _failingClassification,
                    Usage = _usage,
                    ModelUsed = modelId,
                },
                new DecisionTrace($"Invoked model '{modelId}'", "W7D test seam: declared failing.", [])));
        }

        var reply = _replies[System.Math.Min(Invocations.Count - 1, _replies.Count - 1)];

        return Task.FromResult(new ModelStepResult(
            new ModelInvocationResult
            {
                Success = true,
                Message = new ModelMessage { Role = ModelRole.Assistant, Content = reply },
                Usage = _usage,
                ModelUsed = modelId,
            },
            new DecisionTrace($"Invoked model '{modelId}'", "W7D test seam.", [])));
    }
}

/// <summary>One recorded provider invocation, with the prompt that was sent.</summary>
internal sealed record RecordedModelInvocation(
    string ModelId,
    AssembledPrompt Prompt,
    IReadOnlyList<ToolDescriptor> Tools);

/// <summary>The tool seam, recording every invocation it receives and succeeding when called.</summary>
/// <remarks>
/// It succeeds rather than failing, deliberately. A gateway that refuses would make "the tool did not
/// execute" indistinguishable from "the tool was asked and declined", and the claim under test is that
/// nothing ever asked it.
/// </remarks>
internal sealed class RecordingToolGateway : IToolGateway
{
    /// <summary>Every invocation received, in order. Empty means no tool was ever reached.</summary>
    public List<ToolInvocation> Invocations { get; } = [];

    /// <summary>How many times a tool was reached. Zero is the assertion the refusals rely on.</summary>
    public int Count => Invocations.Count;

    public Task<ToolResult> InvokeAsync(ToolInvocation invocation, CancellationToken ct = default)
    {
        Invocations.Add(invocation);

        return Task.FromResult(new ToolResult { Success = true, OutputJson = "{\"ok\":true}" });
    }
}
