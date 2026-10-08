using Nexus.Intelligence.Agents;
using Nexus.Intelligence.Agents.Abstractions;
using Nexus.Intelligence.Agents.BuiltIn;
using Nexus.Intelligence.Api.Operations;
using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Execution;
using Nexus.Intelligence.Core.Gateway;
using Nexus.Intelligence.Core.Governance;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Planning;
using Nexus.Intelligence.Core.Registry;
using Nexus.Intelligence.Core.Roles;
using Nexus.Intelligence.Core.Routing;
using Nexus.Intelligence.Core.Turns;
using Nexus.Intelligence.Memory;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;
using Nexus.Platform.Core.Models;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Nexus.Intelligence.Api.DependencyInjection;

public static class IntelligenceServiceCollectionExtensions
{
    public static IServiceCollection AddNexusIntelligence(this IServiceCollection services, IConfiguration configuration)
    {
        // W5G / F-01: the model domain is registered HERE now, and only here. These three
        // registrations used to live in Nexus.Platform.Core's AddNexusAi and were reached
        // through AddNexusPlatform. F-01 moved the types to the AI Head, so the AI Head
        // registers them; AddNexusAi is deleted, and the republished Nexus.Platform.Core
        // no longer contains an AddNexusPlatform that could re-register them.
        //
        // That is what closes the duplicate-identity hazard rather than merely moving it: if
        // the old Nexus.Platform.Core package were still referenced, its AddNexusPlatform
        // would register IModelCatalog/IModelGateway/IUsageMeter against ITS copy of the
        // model domain while this method registers the same three interfaces against this
        // repository's copy. Two registrations, two implementations, last-one-wins, no
        // compile error - a split DI graph that no test would have caught.
        //
        // Contract/implementation ownership stays as it was: IModelCatalog, IModelGateway and
        // IUsageMeter are the platform-neutral CONTRACTS (Nexus.Platform.Contracts.Models,
        // consumed as a pinned package across the PL-04 Contract Plane), and the
        // implementations are AI-owned.
        services.AddSingleton<IModelCatalog, AggregatingModelCatalog>();
        services.AddSingleton<IModelGateway, RoutingModelGateway>();
        services.AddSingleton<IUsageMeter, InMemoryUsageMeter>();

        services.AddSingleton<IContextRanker, KeywordContextRanker>();
        services.AddSingleton<IPromptAssembler, PromptAssembler>();

        services.AddSingleton<IMemoryStore, InMemoryMemoryStore>();

        // Roles and their assignments are data, seeded from configuration rather than written here.
        //
        // W7C TASK 7 (OOS-3): this seed named "openai:gpt-4.1" as a string literal. The assignment type
        // already documented that swapping a role's model "requires only a configuration change, never a
        // code change" - but the seed was code, so the documented property was false for the one role
        // the estate actually runs. The literal is gone; the seed is now Ai:Roles, parsed by
        // AiRoleSeedParser, whose failure modes (a misspelt capability, a duplicated role) are caught
        // here at composition.
        //
        // An estate with no Ai:Roles section seeds no roles, role resolution then finds nothing, and the
        // turn pipeline refuses. That is the correct reading of "no roles are declared" and it is
        // preferable to a built-in role pointing at a model nobody chose.
        var roleSeed = AiRoleSeedParser.Parse(
            configuration.GetSection(AiRoleSeedOptions.SectionName).Get<AiRoleSeedOptions>()
                ?? new AiRoleSeedOptions());

        services.AddSingleton<IAiRoleStore>(_ => new InMemoryAiRoleStore(
            seedRoles: [.. roleSeed.Select(seed => seed.Role)],
            seedAssignments: [.. roleSeed.Select(seed => seed.Assignment)]));

        services.AddSingleton<IAgent, DeveloperAgent>();
        services.AddSingleton<IAgentRegistry, AgentRegistry>();
        services.AddSingleton<IAgentRuntime, AgentRuntime>();
        services.AddSingleton<IAgentDispatcher, AgentDispatcher>();

        services.AddSingleton<IIntentClassifier, IntentClassifier>();
        services.AddSingleton<IPolicyGate, PolicyGate>();
        services.AddSingleton<IContextSelector, ContextSelector>();
        services.AddSingleton<IAgentSelector, AgentSelector>();
        services.AddSingleton<IAiRoleResolver, AiRoleResolver>();
        services.AddSingleton<IPromptStep, PromptStep>();
        services.AddSingleton<IModelStep, ModelStep>();
        services.AddSingleton<IToolLoop, ToolLoop>();
        services.AddSingleton<IResponseComposer, ResponseComposer>();
        services.AddSingleton<ITurnTraceStore, InMemoryTurnTraceStore>();

        services.AddSingleton<IPlanner, Planner>();
        services.AddSingleton<IExecutionEngine, ExecutionEngine>();

        // W7C: the model, provider and health registry, and the router that reads it.
        //
        // Built EAGERLY, here, rather than resolved lazily from a factory. ConfiguredAiRegistry parses
        // and validates in its constructor, and its contract is that a malformed registry fails at
        // composition - a factory would move that failure to whichever request first needed a route,
        // where it would surface as a routing refusal and point the investigation at the wrong file.
        //
        // The same instance answers all three ports. They are three read surfaces over one parse, so
        // registering the same object three times is the point: there is no second registry to drift
        // from the first.
        var registryConfiguration =
            configuration.GetSection(AiRegistryConfiguration.SectionName).Get<AiRegistryConfiguration>()
            ?? new AiRegistryConfiguration();

        var registry = new ConfiguredAiRegistry(registryConfiguration);

        services.AddSingleton<IAiModelRegistry>(registry);
        services.AddSingleton<IAiProviderRegistry>(registry);

        // W7D TASK 2, 3 and 6: the agent, tool and prompt registries.
        //
        // The same instance again, for the same reason as the three above: six read surfaces over one
        // parse of one file. An agent therefore cannot exist in the registry the turn pipeline selects
        // from and not in the register the governance engine reads, because there is one object and the
        // question is which of its methods answered.
        services.AddSingleton<IAiAgentRegistry>(registry);
        services.AddSingleton<IAiToolRegistry>(registry);
        services.AddSingleton<IAiPromptRegistry>(registry);

        var routingPolicy = AiRoutingPolicy.From(registryConfiguration.Routing);
        services.AddSingleton(routingPolicy);

        // W7B: AI Governance.
        //
        // The register is now the real one: it projects governance records from the registry above, so
        // a model's approval status and its capability facts are written once and read by both the
        // router and the governance engine. What it does NOT do is approve anything. Every model and
        // provider arrives with whatever approval its configuration declares, and the committed
        // appsettings declares none - so the estate still refuses rather than permits until an operator
        // records an approval. That is the same fail-closed starting state W7B shipped with; W7C
        // changed where the register reads from, not what it concludes.
        //
        // W7D closed the gap this comment used to describe. The register now resolves all four resource
        // kinds from the one registry, so an agent or an instruction set is written once and both the
        // component that selects it and the engine that governs it read the same record. The refusals did
        // not move: an agent absent from the registry is still AgentUnregistered and an unapproved one is
        // still AgentNotApproved. What changed is that an estate can now reach a state where those rules
        // do not fire, instead of there being no configuration under which an agent could act.
        services.AddSingleton<IAiGovernanceRegister>(
            new RegistryAiGovernanceRegister(registry, registry, registry, registry));

        // The policy is Default() with the register taken from the container rather than copied from
        // Default()'s own field, so the register is resolved and a later lane that registers a real one
        // changes the policy without this method being edited. Every other table in Default() is closed
        // on purpose: the conservative exposure table and a trust floor that refuses anything
        // unassessed. Widening any of them is a governance act with a record, not an edit here.
        services.AddSingleton(provider => AiGovernancePolicy.Default() with
        {
            Register = provider.GetRequiredService<IAiGovernanceRegister>(),

            // W7D TASK 3: the tool effect table, projected from the tool registry.
            //
            // It arrives through the policy rather than through a fifth method on IAiGovernanceRegister,
            // and that is a deliberate choice about which interface should grow. The register answers
            // "does this thing exist and is it approved"; a tool's effect class is not an approval
            // question, it is a property of the tool, and AiGovernancePolicy already owns Tools as the
            // place those properties live. Adding a TryResolveTool to the register would have made the
            // register the authority for two different kinds of fact and would have changed a W7B
            // interface that other lanes are written against.
            //
            // The rule identifiers are derived from the tool identifiers in the registry, so a tool
            // cannot be registered without acquiring a classification: an entry with no SideEffect is
            // refused by the registry's own parse, before this projection ever runs.
            Tools = [.. provider.GetRequiredService<IAiToolRegistry>().GovernanceRules],
        });

        // The exposure table, registered once and read by both the evaluator and the context builder. One
        // instance because the builder compares each item against the same rows the evaluator gated on,
        // and two tables would be two answers to "may this go there".
        services.AddSingleton(provider => provider.GetRequiredService<AiGovernancePolicy>().Exposure);

        // A singleton because the policy tables and the evaluator are immutable and hold no per-request
        // state. A scoped registration would imply the evaluator accumulates something, and an
        // accumulating governance engine is one whose verdict depends on what it has already seen.
        services.AddSingleton<IDataExposurePolicyEvaluator>(provider =>
            new DeclaredClassificationExposureEvaluator(
                provider.GetRequiredService<AiGovernancePolicy>().Exposure));
        services.AddSingleton<IAiGovernanceEvaluator>(provider => new DeterministicAiGovernanceEvaluator(
            provider.GetRequiredService<AiGovernancePolicy>(),
            provider.GetRequiredService<IDataExposurePolicyEvaluator>()));

        // W7D TASKS 4 and 5: the rest of the data-exposure path.
        //
        // Only the evaluator was registered before this lane, so two of the three stages the exposure
        // model describes had implementations and no caller. The live path forwarded the caller's context
        // unredacted and unfiltered to whoever ranked it, which made the exposure table a gate on a
        // question with no consequence.
        //
        // Both are stateless and both are provider-agnostic by contract: a redactor answers what may be
        // sent, never which provider receives it. Filtering tuned to one provider's handling would put
        // provider knowledge above the boundary whose purpose is to keep it below.
        services.AddSingleton<IContextBuilder, FilteringContextBuilder>();
        services.AddSingleton<IContextRedactor, RedactingContextRedactor>();

        // ---- W7E: the operational plane ---------------------------------------------------------
        //
        // Wired here, between the governance plane above and the router below, because that is the
        // order the directive requires at runtime and a composition root that registered it in a
        // different order would be describing a different system than the one it builds.
        //
        // Nothing below is constructed lazily. The budget and reliability policies validate in their
        // parse, so a malformed ceiling table or an out-of-range rate stops the process at startup
        // rather than surfacing later as a routing refusal that points at a provider.
        services.TryAddSingleton(TimeProvider.System);

        var operationsConfiguration = configuration
            .GetSection(AiOperationsConfiguration.SectionName)
            .Get<AiOperationsConfiguration>() ?? new AiOperationsConfiguration();

        var operationsBudget = operationsConfiguration.BudgetPolicy();
        var reliabilityPolicy = operationsConfiguration.ReliabilityPolicy();
        var circuitPolicy = operationsConfiguration.CircuitPolicy();

        services.AddSingleton(operationsBudget);
        services.AddSingleton(reliabilityPolicy);
        services.AddSingleton(circuitPolicy);

        // The health source is now a snapshot, and it is the SAME health the registry used to answer
        // with — read once, at composition, into the shape the probes publish. The registry no longer
        // answers IAiModelHealthSource at all: leaving it registered would have left two health sources
        // in the container, and last-one-wins would have made which one routing read a property of
        // registration order.
        //
        // From here on, a routing decision reads the last published snapshot and never probes. That is
        // structural: the router holds an IAiModelHealthSource, SnapshotAiHealthSource has no probe
        // and no way to reach one, and the only writer of the store is the out-of-band sweep below.
        services.AddSingleton<IAiHealthSnapshotStore>(provider => new InMemoryAiHealthSnapshotStore(
            SeededAiHealthSnapshot.From(
                registryConfiguration,
                provider.GetRequiredService<TimeProvider>().GetUtcNow())));
        services.AddSingleton<IAiModelHealthSource, SnapshotAiHealthSource>();

        // One ledger, two ports. The usage read model and the cost read model are two questions asked
        // of one record of what happened; two stores would be two answers, and they would disagree the
        // first time one write path failed.
        services.AddSingleton<InMemoryAiOperationsLedger>();
        services.AddSingleton<IAiUsageLedger>(provider => provider.GetRequiredService<InMemoryAiOperationsLedger>());
        services.AddSingleton<IAiCostLedger>(provider => provider.GetRequiredService<InMemoryAiOperationsLedger>());

        // Pricing is read from the registry's own rate metadata rather than from a second price list.
        // A catalogue of its own would let a route be costed at one rate by the gates and another by
        // the ledger, and the disagreement would be invisible until a budget was breached.
        services.AddSingleton<IAiPriceCatalogue, ConfiguredAiPriceCatalogue>();

        services.AddSingleton<IAiBudgetEvaluator>(provider => new ConfiguredAiBudgetEvaluator(
            provider.GetRequiredService<AiOperationsBudgetPolicy>(),
            provider.GetRequiredService<IAiCostLedger>()));

        services.AddSingleton<IAiReliabilityHistory>(provider => new InMemoryAiReliabilityHistory(
            provider.GetRequiredService<TimeProvider>(),
            operationsConfiguration.ReliabilityHistoryCapacity));

        // The recovery model. Derived from the same history the reliability gate reads, so a circuit
        // and the measurement that opened it can never be two views of two different attempt logs.
        services.AddSingleton<IAiCircuitBreaker>(provider => new ReplayedAiCircuitBreaker(
            provider.GetRequiredService<IAiReliabilityHistory>(),
            provider.GetRequiredService<AiReliabilityPolicy>(),
            provider.GetRequiredService<AiCircuitPolicy>()));

        // The one seam the router consults. Five gates behind one port, because they share an ordering
        // and a verdict; separately injected ports would let a later edit reorder them with nothing
        // recording that the order changed.
        services.AddSingleton<IAiOperationalEligibility>(provider => new GovernedAiOperationalEligibility(
            provider.GetRequiredService<IAiPriceCatalogue>(),
            provider.GetRequiredService<IAiBudgetEvaluator>(),
            provider.GetRequiredService<IAiReliabilityHistory>(),
            provider.GetRequiredService<AiReliabilityPolicy>(),
            provider.GetRequiredService<IAiCircuitBreaker>(),
            provider.GetRequiredService<AiCircuitPolicy>()));

        // The failover selector reads the SAME operational gate the router does, so a candidate that
        // could not have been routed to cannot be fallen back to. Two instances would be two readings
        // of one reliability history taken at two instants, and the second would be the one an operator
        // never sees.
        services.AddSingleton<IAiFailoverSelector>(provider => new GovernedAiFailoverSelector(
            provider.GetRequiredService<IAiOperationalEligibility>(),
            provider.GetRequiredService<IAiModelHealthSource>(),
            provider.GetRequiredService<IAiModelRegistry>(),
            provider.GetRequiredService<IAiProviderRegistry>()));

        // One sink, two ports: the emitter writes to it and the read model reads from it. The audit
        // record is the spine of the operations read model, so a second sink would mean an execution
        // visible through one surface and absent from the other.
        services.AddSingleton<InMemoryAiAuditSink>();
        services.AddSingleton<IAiAuditSink>(provider => provider.GetRequiredService<InMemoryAiAuditSink>());
        services.AddSingleton<IAiAuditReader>(provider => provider.GetRequiredService<InMemoryAiAuditSink>());

        services.AddSingleton<IAiExecutionEvidenceStore, InMemoryAiExecutionEvidenceStore>();
        services.AddSingleton<IAiAuditEmitter, AiAuditEmitter>();

        // W7F TASK 2: the execution identity source. Registered as a singleton rather than resolved
        // inline so that the governed path's identities come from one place an operator can replace —
        // and so that a test can substitute a deterministic source without reaching into the execution
        // path. Nothing security-bearing depends on the default's randomness; see IAiExecutionIdSource.
        services.AddSingleton<IAiExecutionIdSource, GuidAiExecutionIdSource>();

        services.AddSingleton(provider => new AiOperationsRecorder(
            provider.GetRequiredService<IAiUsageLedger>(),
            provider.GetRequiredService<IAiPriceCatalogue>(),
            provider.GetRequiredService<IAiReliabilityHistory>(),
            provider.GetRequiredService<IAiExecutionEvidenceStore>(),
            provider.GetRequiredService<IAiAuditEmitter>()));

        services.AddSingleton<IAiOperationsReadModel>(provider => new AiOperationsReadModel(
            provider.GetRequiredService<IAiAuditReader>(),
            provider.GetRequiredService<IAiUsageLedger>(),
            provider.GetRequiredService<IAiCostLedger>(),
            provider.GetRequiredService<IAiExecutionEvidenceStore>()));

        // The probe sweep, composed only where an estate asked for it. With no probe registered the
        // sweep still runs on schedule and republishes the declared snapshot unchanged, which is a
        // visible, running, inconclusive sweep rather than a silent absence — and it is why this lane
        // needs no provider credential to be composed or tested.
        services.AddSingleton<IAiHealthProbeRunner>(provider => new ConfiguredAiHealthProbeRunner(
            registryConfiguration,
            provider.GetServices<IAiHealthProbe>(),
            provider.GetRequiredService<IAiHealthSnapshotStore>(),
            provider.GetRequiredService<TimeProvider>()));

        // Composed by factory rather than by type, because the interval is a value the container cannot
        // hold: TimeSpan is a struct and every AddSingleton overload that takes an instance requires a
        // reference type. Creating the service through ActivatorUtilities passes the interval as an
        // explicit argument and resolves the runner and the logger from the container as usual.
        if (operationsConfiguration.ProbeInterval is { } probeInterval)
        {
            services.AddHostedService(provider => ActivatorUtilities.CreateInstance<AiHealthProbeService>(
                provider,
                probeInterval));
        }

        // W7C: the router.
        //
        // Composed from the registries and gates above and nothing else. A singleton for the same reason
        // the evaluator is one: it holds no per-request state, and a router that accumulated any would
        // be one whose next decision depended on its last.
        //
        // The operational gate is a constructor parameter rather than an optional one. An estate that
        // wants no operational plane configures the policies to say so; it does not get that state by
        // the router having been built without the gates, because then "the gates permitted this" and
        // "the gates were never asked" would be the same outcome.
        //
        // What was NOT registered before W7D, and is now: the governed execution path. The comment this
        // replaces said that wiring the invocation seam was W7D's work. This is that wiring.
        //
        // TurnPipeline depends on IGovernedTurnExecution and on nothing else that can reach a model. It
        // holds no model selector, no model step and no tool loop, so the live path has exactly one way
        // to reach a provider and that way runs the exposure path, the W7B engine and the W7C router in
        // that order. The bypass that existed before this lane existed because the pipeline held the
        // ports itself; it is not closed by a check inside the pipeline but by the pipeline no longer
        // having anything to check.
        services.AddSingleton<IAiCapabilityRouter>(provider => new GovernedCapabilityRouter(
            provider.GetRequiredService<IAiModelRegistry>(),
            provider.GetRequiredService<IAiProviderRegistry>(),
            provider.GetRequiredService<IAiModelHealthSource>(),
            provider.GetRequiredService<IAiGovernanceEvaluator>(),
            provider.GetRequiredService<IAiOperationalEligibility>(),
            provider.GetRequiredService<AiRoutingPolicy>(),
            provider.GetRequiredService<TimeProvider>()));

        services.AddSingleton<IGovernedTurnExecution>(provider => new GovernedTurnExecution(
            provider.GetRequiredService<IAiCapabilityRouter>(),
            provider.GetRequiredService<IAiGovernanceEvaluator>(),
            provider.GetRequiredService<IDataExposurePolicyEvaluator>(),
            provider.GetRequiredService<AiGovernancePolicy>().Exposure,
            provider.GetRequiredService<IContextBuilder>(),
            provider.GetRequiredService<IContextRedactor>(),
            provider.GetRequiredService<IContextSelector>(),
            provider.GetRequiredService<IAiPromptRegistry>(),
            provider.GetRequiredService<IAiToolRegistry>(),
            provider.GetRequiredService<IPromptStep>(),
            provider.GetRequiredService<IModelStep>(),
            provider.GetRequiredService<IToolLoop>(),
            provider.GetRequiredService<IAiFailoverSelector>(),
            provider.GetRequiredService<AiOperationsRecorder>(),
            provider.GetRequiredService<IAiExecutionIdSource>(),
            provider.GetRequiredService<TimeProvider>()));

        services.AddSingleton<ITurnPipeline, TurnPipeline>();

        // ---- W7F TASK 1, 7 and 14: the gateway ---------------------------------------------------
        //
        // Taken from the policy rather than constructed here, and that is the whole registration. The
        // register the gateway lists capabilities from and the register governance authorises against
        // are the same object, so a capability cannot be advertised by the gateway to a caller and be
        // unknown to the engine that would have to permit it — the two questions would be answered from
        // two sources and would disagree the first time one was edited.
        services.AddSingleton(provider => provider.GetRequiredService<AiGovernancePolicy>().Capabilities);

        // The projection, not the snapshot store. This registration is the boundary TASK 7 draws: the
        // gateway and the transport hold an IAiGatewayAvailabilitySource, which names no provider and no
        // model, and the IAiHealthSnapshotStore that names both is reachable from the operations surface
        // alone. A transport that resolved the store directly could publish provider health through a
        // caller-facing route without any type in between reading wrong.
        services.AddSingleton<IAiGatewayAvailabilitySource, AiGatewayAvailabilityProjection>();

        // One implementation, two roles. Nothing else in this container implements IAiCapabilityClient,
        // deliberately: TASK 9 forbids a competing second AI client, and a second registration here
        // would be that client with last-one-wins deciding which one a caller got.
        //
        // The transport resolves this by interface, so the API project never names AiCapabilityGateway
        // and cannot reach the governed path, the router or the registry through it. The gateway is the
        // only thing between a request body and the estate, and it has one way to execute.
        services.AddSingleton<IAiCapabilityClient>(provider => new AiCapabilityGateway(
            provider.GetRequiredService<IGovernedTurnExecution>(),
            provider.GetRequiredService<IAiGatewayAvailabilitySource>(),
            provider.GetRequiredService<AiCapabilityRegister>(),
            provider.GetRequiredService<IAiOperationsReadModel>(),
            provider.GetRequiredService<IToolCatalog>(),
            provider.GetRequiredService<IAiExecutionIdSource>(),
            provider.GetRequiredService<TimeProvider>()));

        return services;
    }
}
