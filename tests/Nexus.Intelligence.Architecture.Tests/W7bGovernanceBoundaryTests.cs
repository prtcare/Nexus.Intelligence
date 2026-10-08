using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Nexus.Intelligence.Api.DependencyInjection;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Governance;
using Nexus.Intelligence.Core.Registry;
using Nexus.Platform.Core;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7B: the structural half of AI Governance.
//
// The behaviour suite proves what the engine DECIDES. This suite proves what the engine and its
// contracts CANNOT DO - which is a different claim, and the one the directive states as a prohibition
// list: AI Governance must not directly merge Git, deploy, alter protected architecture, access
// credentials or bypass Platform Governance.
//
// Those are not claims about behaviour, so no behavioural test can hold them. A future lane could add a
// branch that shells out to git and every decision test would still pass. What CAN hold them is the
// shape of the types: an engine that holds no HTTP client cannot call a deployment API, one that names
// no process type cannot run git, and one whose only output is a decision record has nothing a caller
// could execute with.
//
// Every detector below is paired with a control that must produce the opposite result, because a
// reflection scan that reaches nothing reports success forever.
public sealed class W7bGovernanceBoundaryTests
{
    // ---------------------------------------------------------------------------------------------
    // (a) The governance engine cannot act on the world. It can only decide.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void GovernanceSurface_HoldsNoCapabilityToAct()
    {
        var leaks = GovernanceGraph()
            .SelectMany(host => DeclaredMemberTypes(host).Select(member => (host, member)))
            .Where(pair => IsActingCapability(pair.member))
            .Select(pair => $"{pair.host.Name} -> {pair.member.FullName}")
            .Distinct()
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();

        Assert.True(
            leaks.Length == 0,
            "[W7B] A governance type holds a capability to act rather than to decide. An engine that "
            + "can make an outbound call, run a process, write a file or reach credential material is "
            + "one whose refusal is not the end of the story. Offenders: " + string.Join(", ", leaks));
    }

    // The control. Each planted type holds one genuine capability of the shape the rule forbids, so a
    // detector with a mis-typed namespace, an empty graph or an inverted predicate fails here rather
    // than passing quietly above.
    [Fact]
    public void ActingCapabilityDetector_IsNonVacuous_OnPlantedCapabilities()
    {
        // Outbound call: the shape a provider invocation or a deployment API call would need.
        Assert.True(
            IsActingCapability(typeof(System.Net.Http.HttpClient)),
            "The detector does not recognise an HTTP client, so the rule above cannot see a governance "
            + "type that could call out.");

        // Process: the shape that runs git, a deploy script or a shell.
        Assert.True(
            IsActingCapability(typeof(System.Diagnostics.Process)),
            "The detector does not recognise a process type, so a governance type could shell out to git "
            + "without failing the rule above.");

        // Credential material, reached through the Platform contract plane's own resolver.
        Assert.True(
            IsActingCapability(typeof(Nexus.Platform.Contracts.Secrets.ISecretResolver)),
            "The detector does not recognise the secret resolver, so a governance type could hold the "
            + "means to resolve a credential without failing the rule above.");

        // File writes: the shape that alters source, configuration or protected architecture.
        Assert.True(
            IsActingCapability(typeof(System.IO.StreamWriter)),
            "The detector does not recognise a file writer, so a governance type could modify the "
            + "repository without failing the rule above.");

        // A provider implementation, so the vendor boundary is included in the scan.
        Assert.True(
            IsActingCapability(typeof(Nexus.Platform.Providers.OpenAI.OpenAIOptions)),
            "The detector does not recognise a provider implementation type.");

        // ...and it must not flag ordinary decision vocabulary, or the rule would be satisfied by
        // removing the decision rather than by removing the capability.
        foreach (var benign in new[]
                 {
                     typeof(AiGovernanceDecision),
                     typeof(AiGovernancePolicy),
                     typeof(AiGovernanceVerdict),
                     typeof(AiFailureCategory),
                     typeof(System.Collections.Generic.IReadOnlyList<string>),
                     typeof(System.Threading.Tasks.Task<AiGovernanceDecision>),
                 })
        {
            Assert.False(
                IsActingCapability(benign),
                $"The detector flags {benign.Name}, which is decision vocabulary. The rule would then be "
                + "satisfied by renaming rather than by removing the capability.");
        }
    }

    // The graph the scan runs over must actually contain the engine. Without this, a root list typo
    // would leave the scan walking three types and the rule above would be near-vacuous.
    [Fact]
    public void GovernanceGraph_ReachesTheEngineItself()
    {
        var graph = GovernanceGraph();

        Assert.Contains(typeof(DeterministicAiGovernanceEvaluator), graph);
        Assert.Contains(typeof(IAiGovernanceEvaluator), graph);
        Assert.Contains(typeof(GovernedProviderInvocation), graph);

        // And it must DESCEND rather than merely collect the roots. Each type below is reachable from the
        // roots only through a member, so an empty or unwired walker fails here. Asserted by naming types
        // rather than by a type count, because a count is a number nobody can justify: it would have to be
        // raised whenever a record was added and lowered whenever one was removed, and neither edit would
        // mean anything.
        foreach (var reached in new[]
                 {
                     typeof(AiGovernancePolicy),
                     typeof(AiGovernanceBudgetRule),
                     typeof(AiGovernanceToolRule),
                     typeof(AiGovernanceEscalationRule),
                     typeof(AiFailure),
                     typeof(DataExposureRule),
                     typeof(CapabilityId),
                 })
        {
            Assert.True(
                graph.Contains(reached),
                $"The governance graph did not reach {reached.Name}, so the scan is not walking the "
                + "surface it claims to cover.");
        }

        // The graph is Nexus-only: framework types reached as members are checked as held types, not
        // scanned as hosts. Asserted because including them is what made the first draft of this suite
        // report System.Type's own attributes as governance defects.
        Assert.True(
            graph.All(t => t.Assembly == ContractsAssembly || t.Assembly == CoreAssembly),
            "The governance graph contains a type from outside the governance assemblies.");
    }

    // ---------------------------------------------------------------------------------------------
    // (b) No provider implementation and no vendor is reachable from governance.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void GovernanceAssemblies_ReferenceNoProviderImplementation()
    {
        foreach (var assembly in new[] { ContractsAssembly, CoreAssembly })
        {
            var references = assembly.GetReferencedAssemblies()
                .Select(a => a.Name ?? string.Empty)
                .Where(IsProviderOrVendorAssembly)
                .ToArray();

            Assert.True(
                references.Length == 0,
                $"[W7B] {assembly.GetName().Name} references a provider implementation or vendor "
                + "assembly. Governance decides about providers; it must not be built on one. Offenders: "
                + string.Join(", ", references));
        }
    }

    // The control: the provider assembly this rule names must be loadable, or the negative above would
    // pass because the name was misspelt rather than because the reference is absent.
    [Fact]
    public void ProviderAssemblyNamedByTheRule_IsLoadable()
    {
        var provider = Assembly.Load("Nexus.Platform.Providers.OpenAI");

        Assert.True(IsProviderOrVendorAssembly("Nexus.Platform.Providers.OpenAI"));

        // NEGATIVE: an ordinary contract assembly is not flagged, so the predicate is a test and not a
        // constant.
        Assert.False(IsProviderOrVendorAssembly("Nexus.Intelligence.Contracts"));
        Assert.False(IsProviderOrVendorAssembly("Nexus.Platform.Contracts"));

        // And the provider really is a distinct assembly carrying a vendor namespace, so the rule above
        // is about a real boundary rather than about a name that nothing could match.
        Assert.Contains(
            provider.GetExportedTypes(),
            t => t.Namespace?.StartsWith("Nexus.Platform.Providers", StringComparison.Ordinal) == true);
    }

    // ---------------------------------------------------------------------------------------------
    // (c) Resources are data. No list of models, providers, agents, prompts or tools lives in code.
    // ---------------------------------------------------------------------------------------------

    // The directive's "prefer registries and policy records over hardcoded provider and model lists",
    // made structural: every element of every static string collection in the governance surface must be
    // an identifier of a GOVERNED VOCABULARY - a rule of this contract or a platform authority - because
    // those name checks the engine performs. Anything else in such a collection would be membership, and
    // membership is what the register and the policy tables exist to hold.
    [Fact]
    public void StaticStringCollectionsInGovernance_HoldVocabularyIdentifiersOnly()
    {
        var collections = GovernanceGraph()
            .SelectMany(host => host
                .GetFields(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static)
                .Where(f => IsStaticStringCollection(f.FieldType))
                .Select(f => (host, field: f)))
            .ToArray();

        // Non-vacuity: the rule is about collections that exist. If the vocabulary were ever removed
        // from static storage this assertion fails rather than the loop below passing over nothing.
        Assert.NotEmpty(collections);

        var elements = new List<(Type Host, string Field, string Value)>();

        foreach (var (host, field) in collections)
        {
            var value = field.GetValue(null);

            foreach (var element in AsStrings(value))
            {
                elements.Add((host, field.Name, element));
            }
        }

        Assert.NotEmpty(elements);

        var offenders = elements
            .Where(e => !AiGovernanceRules.IsKnown(e.Value) && !IsPlatformAuthority(e.Value))
            .Select(e => $"{e.Host.Name}.{e.Field} contains '{e.Value}'")
            .Distinct()
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();

        Assert.True(
            offenders.Length == 0,
            "[W7B] A static string collection in the governance surface holds something that is neither "
            + "a governance rule nor a platform authority. A static list of models, providers, agents, "
            + "prompts or tools is the hardcoded resource list the register and the policy records exist "
            + "to replace. Offenders: " + string.Join(", ", offenders));

        // Both vocabularies are represented, so the check above is not passing on one of them alone.
        Assert.Contains(elements, e => AiGovernanceRules.IsKnown(e.Value));
        Assert.Contains(elements, e => IsPlatformAuthority(e.Value));
    }

    // The control for the predicate the rule above rests on.
    [Fact]
    public void StaticStringCollectionDetector_IsNonVacuous_OnPlantedLists()
    {
        Assert.True(IsStaticStringCollection(typeof(string[])));
        Assert.True(IsStaticStringCollection(typeof(IReadOnlyList<string>)));
        Assert.True(IsStaticStringCollection(typeof(List<string>)));
        Assert.True(IsStaticStringCollection(typeof(IReadOnlyDictionary<string, string>)));

        // NEGATIVE: an enum collection is not a string collection, and the prohibition baseline's surface
        // list is deliberately allowed to exist - a protected surface is a closed set the contract may
        // name, whereas a model is not.
        Assert.False(IsStaticStringCollection(typeof(AiProhibitedSurface[])));
        Assert.False(IsStaticStringCollection(typeof(string)));
        Assert.False(IsStaticStringCollection(typeof(int)));

        // And a planted resource list must be caught by the rule's predicate, not merely by its type.
        foreach (var planted in new[] { "openai:gpt-4.1", "gpt-4o", "claude-sonnet-5", "model-w7b" })
        {
            Assert.False(
                AiGovernanceRules.IsKnown(planted) || IsPlatformAuthority(planted),
                $"'{planted}' would be accepted as vocabulary, so a hardcoded model list would pass the "
                + "rule above.");
        }
    }

    // A `const string` is the other way a resource identifier gets into code, and unlike a run-time
    // literal it is enumerable. Every const string in the governance surface must be a vocabulary
    // identifier for the same reason a static collection's elements must be.
    [Fact]
    public void ConstStringsInGovernance_AreVocabularyIdentifiersOnly()
    {
        var consts = GovernanceGraph()
            .SelectMany(host => host
                .GetFields(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static)
                .Where(f => f.IsLiteral && f.FieldType == typeof(string))
                .Select(f => (host, value: f.GetRawConstantValue() as string, field: f)))
            .ToArray();

        Assert.NotEmpty(consts);

        var offenders = consts
            .Where(c => c.value is null || (!AiGovernanceRules.IsKnown(c.value) && !IsPlatformAuthority(c.value)))
            .Select(c => $"{c.host.Name}.{c.field.Name} = '{c.value}'")
            .Distinct()
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();

        Assert.True(
            offenders.Length == 0,
            "[W7B] A const string in the governance surface is not a vocabulary identifier. A model id, "
            + "a provider id or an endpoint written as a constant is a hardcoded list of at most one "
            + "element, and it fails the same requirement. Offenders: " + string.Join(", ", offenders));
    }

    // Determinism is a property of the type, not only of the run: a mutable static field is process
    // state, and a governance decision that can depend on process state is one that can differ between
    // two identical requests.
    [Fact]
    public void GovernanceSurface_HoldsNoMutableStaticState()
    {
        var mutable = GovernanceGraph()
            .SelectMany(host => host
                .GetFields(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static)
                .Where(f => !f.IsLiteral && !f.IsInitOnly)
                .Select(f => $"{host.Name}.{f.Name}"))
            .Distinct()
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();

        Assert.True(
            mutable.Length == 0,
            "[W7B] The governance surface holds a mutable static field. A static that can change after "
            + "composition makes a decision depend on what the process has already done, which is the "
            + "one thing a deterministic gate may not do. Offenders: " + string.Join(", ", mutable));
    }

    // ---------------------------------------------------------------------------------------------
    // (d) The gate is synchronous and has exactly one entrance.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheGate_ExposesNoAsynchronousExecutionEntryPoint()
    {
        var offenders = new[] { typeof(IAiGovernanceEvaluator), typeof(DeterministicAiGovernanceEvaluator) }
            .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static
                                          | BindingFlags.DeclaredOnly)
                .Select(m => (Type: t, Method: m)))
            .Where(pair => ReturnsAwaitable(pair.Method.ReturnType))
            .Select(pair => $"{pair.Type.Name}.{pair.Method.Name}")
            .Distinct()
            .ToArray();

        Assert.True(
            offenders.Length == 0,
            "[W7B] The governance gate exposes an awaitable member. A decision that can be awaited is a "
            + "decision that can be made alongside a provider call, and the first implementation to do "
            + "that has made the verdict depend on something outside the policy table. Offenders: "
            + string.Join(", ", offenders));

        // Non-vacuity: the detector must recognise the shape it is forbidding, and the engine must really
        // have members for the scan above to have been a scan.
        Assert.True(ReturnsAwaitable(typeof(System.Threading.Tasks.Task)));
        Assert.True(ReturnsAwaitable(typeof(System.Threading.Tasks.Task<int>)));
        Assert.True(ReturnsAwaitable(typeof(System.Threading.Tasks.ValueTask)));
        Assert.False(ReturnsAwaitable(typeof(AiGovernanceDecision)));

        Assert.Contains(
            typeof(IAiGovernanceEvaluator).GetMethods(),
            m => m.Name == nameof(IAiGovernanceEvaluator.Evaluate) && !ReturnsAwaitable(m.ReturnType));

        // The evaluator's own Evaluate is synchronous even though one member of the Core seam
        // (GovernedProviderInvocation.InvokeAsync) is not - the await there is the PROVIDER's, and the
        // decision is taken before it.
        Assert.Contains(
            typeof(DeterministicAiGovernanceEvaluator).GetMethods(BindingFlags.Public | BindingFlags.Instance),
            m => m.Name == nameof(DeterministicAiGovernanceEvaluator.Evaluate)
                 && !ReturnsAwaitable(m.ReturnType));
    }

    // ---------------------------------------------------------------------------------------------
    // (e) The composition wires a closed register, not a permissive one.
    // ---------------------------------------------------------------------------------------------

    // The composition root is where the governance lane's starting state is set, and the state that
    // matters is that NOTHING is approved. This resolves the real container and checks that the engine
    // refuses a resource named elsewhere in configuration - the role seed names "openai:gpt-4.1" as the
    // model for the default role, and that name must confer no governance approval at all. The two facts
    // living in separate files and disagreeing is the point: role assignment is not approval, and only
    // the governance register is approval.
    //
    // W7C UPDATED THIS TEST. It previously asserted that the composed register was
    // EmptyAiGovernanceRegister.Instance - a statement about the W7B-ONLY composition, where no registry
    // existed yet. W7C's mandate is "one authoritative model registry" with W7B governance integrated,
    // so the composition root now supplies RegistryAiGovernanceRegister over the configured registry.
    // The change below tracks that, and the second composition STRENGTHENS the check rather than
    // relaxing it: it populates the registry with an enabled, available, approvable-looking
    // "openai:gpt-4.1" and asserts the engine still refuses it, which is the stronger form of "presence
    // in the registry is not approval" that the original assertion could only make by having no registry
    // at all.
    [Fact]
    public void ComposedContainer_ResolvesAClosedGovernanceEngine()
    {
        var configuration = new ConfigurationBuilder().Build();

        using var serviceProvider = new ServiceCollection()
            .AddNexusPlatform(configuration)
            .AddNexusIntelligence(configuration)
            .BuildServiceProvider();

        var evaluator = serviceProvider.GetRequiredService<IAiGovernanceEvaluator>();
        var policy = serviceProvider.GetRequiredService<AiGovernancePolicy>();

        Assert.IsType<DeterministicAiGovernanceEvaluator>(evaluator);

        // The register is the registry-backed one, and it is the same instance the container published
        // rather than a copy Default() carried.
        Assert.IsType<RegistryAiGovernanceRegister>(policy.Register);
        Assert.Same(policy.Register, serviceProvider.GetRequiredService<IAiGovernanceRegister>());

        Assert.Empty(policy.Budgets);
        Assert.Empty(policy.Tools);
        Assert.Empty(policy.Escalations);

        var decision = evaluator.Evaluate(
            new AiGovernanceEvaluationRequest
            {
                RequestId = "req-w7b-composition",
                Capability = CapabilityId.Parse("chat.complete"),
                Requester = new AiRequesterIdentity
                {
                    Head = CallingHead.Ai,
                    PrincipalId = "principal-w7b",
                    PermissionScope = AiPermissionScope.None,
                    DataScopes = [],
                },
                Classification = DataClassification.Public,
                ContextClassifications = [],
                Destination = AiDestinationClass.Local,
                Execution = AiExecutionPolicy.Default,
                Tools = ToolPermissionProfile.None,
                RequestedToolIds = [],
                ModelId = "openai:gpt-4.1",
                CorrelationId = "corr-w7b-composition",
            },
            AiPlatformGovernanceAttestation.NotApplicable);

        Assert.True(decision.IsBlocked, decision.Reason);
        Assert.Equal(AiGovernanceRules.ModelUnregistered, decision.RuleId);

        // NEGATIVE CONTROL: the same composed engine permits a request that names no resource at all, so
        // the refusal above is the closed register and not an engine that refuses everything it is asked.
        var anonymous = evaluator.Evaluate(
            new AiGovernanceEvaluationRequest
            {
                RequestId = "req-w7b-composition-anonymous",
                Capability = CapabilityId.Parse("chat.complete"),
                Requester = new AiRequesterIdentity
                {
                    Head = CallingHead.Ai,
                    PrincipalId = "principal-w7b",
                    PermissionScope = AiPermissionScope.None,
                    DataScopes = [],
                },
                Classification = DataClassification.Public,
                ContextClassifications = [],
                Destination = AiDestinationClass.Local,
                Execution = AiExecutionPolicy.Default,
                Tools = ToolPermissionProfile.None,
                RequestedToolIds = [],
                CorrelationId = "corr-w7b-composition-anonymous",
            },
            AiPlatformGovernanceAttestation.NotApplicable);

        Assert.True(anonymous.IsAllowed, anonymous.Reason);

        // The stronger form of the same claim. An empty configuration leaves the registry empty, so the
        // refusal above could in principle come from an absent registry rather than from an unapproved
        // one. This composition POPULATES the registry with openai:gpt-4.1 - enabled, availability
        // Available, provider egress permitted, everything an operator sets when they intend a model to
        // work - and leaves Approval at its Unregistered default. The engine must still refuse it.
        var populated = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Ai:Registry:Providers:0:ProviderId"] = "openai",
                ["Ai:Registry:Providers:0:DisplayName"] = "OpenAI",
                ["Ai:Registry:Providers:0:AdapterIdentity"] = "Nexus.Platform.Providers.OpenAI",
                ["Ai:Registry:Providers:0:Enabled"] = "true",
                ["Ai:Registry:Providers:0:PermitsRemoteEgress"] = "true",
                ["Ai:Registry:Providers:0:GovernanceRationale"] = "Registered for the W7C composition check.",
                ["Ai:Registry:Models:0:ModelId"] = "openai:gpt-4.1",
                ["Ai:Registry:Models:0:ProviderId"] = "openai",
                ["Ai:Registry:Models:0:DisplayName"] = "GPT-4.1",
                ["Ai:Registry:Models:0:Enabled"] = "true",
                ["Ai:Registry:Models:0:Availability"] = "Available",
                ["Ai:Registry:Models:0:GovernanceRationale"] = "Registered for the W7C composition check.",
            })
            .Build();

        using var populatedProvider = new ServiceCollection()
            .AddNexusPlatform(populated)
            .AddNexusIntelligence(populated)
            .BuildServiceProvider();

        var registry = populatedProvider.GetRequiredService<IAiModelRegistry>();

        // NON-VACUITY: the model really is in the registry, enabled and resolvable. Without this the
        // assertion below would pass on a registry the configuration never reached.
        Assert.True(registry.TryGetModel("openai:gpt-4.1", out var registered), "the model was not registered");
        Assert.NotNull(registered);
        Assert.True(registered!.Enabled, "the registered model is not enabled");
        Assert.Equal(AiGovernanceApprovalStatus.Unregistered, registered.Approval);

        var named = populatedProvider.GetRequiredService<IAiGovernanceEvaluator>().Evaluate(
            new AiGovernanceEvaluationRequest
            {
                RequestId = "req-w7c-populated",
                Capability = CapabilityId.Parse("chat.complete"),
                Requester = new AiRequesterIdentity
                {
                    Head = CallingHead.Ai,
                    PrincipalId = "principal-w7c",
                    PermissionScope = AiPermissionScope.None,
                    DataScopes = [],
                },
                Classification = DataClassification.Public,
                ContextClassifications = [],
                Destination = AiDestinationClass.Local,
                Execution = AiExecutionPolicy.Default,
                Tools = ToolPermissionProfile.None,
                RequestedToolIds = [],
                ModelId = "openai:gpt-4.1",
                ProviderId = "openai",
                CorrelationId = "corr-w7c-populated",
            },
            AiPlatformGovernanceAttestation.NotApplicable);

        Assert.True(named.IsBlocked, named.Reason);

        // ModelNotApproved and NOT ModelUnregistered, and the difference is the whole point. The empty
        // composition above refuses with ModelUnregistered because the model could not be resolved at
        // all; this one resolves it and refuses because its approval status is Unregistered. W7B already
        // separates "no such model" from "a model nobody approved", so the populated composition proves
        // the stronger claim directly: the model is present, enabled and available, and is still refused.
        Assert.Equal(AiGovernanceRules.ModelNotApproved, named.RuleId);
    }

    // ---------------------------------------------------------------------------------------------
    // Detectors.
    // ---------------------------------------------------------------------------------------------

    private static Assembly ContractsAssembly => typeof(AiGovernanceDecision).Assembly;

    private static Assembly CoreAssembly => typeof(GovernedProviderInvocation).Assembly;

    /// <summary>
    /// The governance surface, reached from its roots through declared members.
    /// </summary>
    /// <remarks>
    /// Scoped by reachability rather than by namespace because the governance contract types live in the
    /// flat <c>Nexus.Intelligence.Contracts</c> namespace: the folder is <c>Governance/</c> but the
    /// namespace is the assembly root, so a namespace scan would find almost nothing and the rules above
    /// would pass over an empty set.
    /// </remarks>
    private static HashSet<Type> GovernanceGraph()
    {
        Type[] roots =
        [
            typeof(IAiGovernanceEvaluator),
            typeof(DeterministicAiGovernanceEvaluator),
            typeof(AiGovernanceDecision),
            typeof(AiGovernanceRules),
            typeof(AiGovernanceVerdict),
            typeof(AiGovernanceEvaluationRequest),
            typeof(AiGovernancePolicy),
            typeof(IAiGovernanceRegister),
            typeof(EmptyAiGovernanceRegister),
            typeof(AiModelGovernanceRecord),
            typeof(AiProviderGovernanceRecord),
            typeof(AiAgentGovernanceRecord),
            typeof(AiPromptGovernanceRecord),
            typeof(AiGovernanceSubject),
            typeof(AiGovernanceApprovalStatus),
            typeof(AiProviderTrustTier),
            typeof(AiPlatformGovernanceAttestation),
            typeof(AiGovernanceAuthority),
            typeof(AiProhibitedSurface),
            typeof(AiProhibitionBaseline),
            typeof(AiDependencyClass),
            typeof(AiDependencyRegistry),
            typeof(AiDependencyDeclaration),
            typeof(AiCapabilityRegister),
            typeof(AiCapabilityRegistration),
            typeof(DataExposurePolicy),
            typeof(DataExposureDecision),
            typeof(DeclaredClassificationExposureEvaluator),
            typeof(GovernedProviderInvocation),
            typeof(GovernedInvocationOutcome<>),
        ];

        // Two sets, and the distinction matters. `visited` exists only to terminate the walk over
        // framework types, which form cycles among themselves. `governance` is the result, and it holds
        // Nexus types ONLY: a framework type reached through a member is something a governance type
        // HOLDS and is checked as such, but it is not itself a host to be scanned. Scanning it would
        // report System.Type's own StructLayoutAttribute and Task's factory field as governance defects,
        // which is how a rule acquires noise and then an exemption list.
        var visited = new HashSet<Type>();
        var governance = new HashSet<Type>();
        var queue = new Queue<Type>(roots);

        while (queue.Count > 0)
        {
            var current = queue.Dequeue();

            if (!visited.Add(current))
            {
                continue;
            }

            // Only descend inside the two governance assemblies. A framework type cannot expose a Nexus
            // member, and descending into one would pull in the whole of System.Runtime for nothing.
            var assembly = current.Assembly;
            if (assembly != ContractsAssembly && assembly != CoreAssembly)
            {
                continue;
            }

            governance.Add(current);

            foreach (var member in DeclaredMemberTypes(current))
            {
                queue.Enqueue(member);
            }
        }

        return governance;
    }

    /// <summary>
    /// Every type named by a member of <paramref name="host"/>, public or not, unwrapped through generics.
    /// </summary>
    /// <remarks>
    /// Members are read with <c>DeclaredOnly</c> so a type is judged by what it holds rather than by what
    /// it inherits from <see cref="object"/>, and non-public members are included because a private
    /// field is the natural home for a capability a type does not advertise.
    /// </remarks>
    private static IEnumerable<Type> DeclaredMemberTypes(Type host)
    {
        const BindingFlags Flags =
            BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static
            | BindingFlags.DeclaredOnly;

        foreach (var field in host.GetFields(Flags))
        {
            foreach (var unwrapped in Unwrap(field.FieldType))
            {
                yield return unwrapped;
            }
        }

        foreach (var property in host.GetProperties(Flags))
        {
            foreach (var unwrapped in Unwrap(property.PropertyType))
            {
                yield return unwrapped;
            }
        }

        foreach (var method in host.GetMethods(Flags))
        {
            foreach (var unwrapped in Unwrap(method.ReturnType))
            {
                yield return unwrapped;
            }

            foreach (var parameter in method.GetParameters())
            {
                foreach (var unwrapped in Unwrap(parameter.ParameterType))
                {
                    yield return unwrapped;
                }
            }
        }

        foreach (var constructor in host.GetConstructors(Flags))
        {
            foreach (var parameter in constructor.GetParameters())
            {
                foreach (var unwrapped in Unwrap(parameter.ParameterType))
                {
                    yield return unwrapped;
                }
            }
        }
    }

    private static IEnumerable<Type> Unwrap(Type type)
    {
        if (type.IsByRef || type.IsArray || type.IsPointer)
        {
            var element = type.GetElementType();
            if (element is not null)
            {
                foreach (var inner in Unwrap(element))
                {
                    yield return inner;
                }
            }

            yield break;
        }

        yield return type;

        if (!type.IsGenericType)
        {
            yield break;
        }

        foreach (var argument in type.GetGenericArguments())
        {
            foreach (var inner in Unwrap(argument))
            {
                yield return inner;
            }
        }
    }

    // Namespaces whose types give a governance type the means to act rather than to decide. Each entry
    // answers one clause of the directive: "must not directly merge Git" (process, and a native bridge),
    // "deploy" (outbound call, process), "alter protected architecture" (file writes), "access
    // credentials" (the Platform secret plane and the cryptography namespaces).
    private static readonly string[] ActingNamespaces =
    [
        "System.Net",
        "System.IO",
        "System.Security",
        "System.Runtime.InteropServices",
        "System.Diagnostics",
        "System.Management.Automation",
        "LibGit2Sharp",
        "Nexus.Platform.Providers",
        "Nexus.Platform.Contracts.Secrets",
    ];

    private static bool IsActingCapability(Type type)
    {
        var ns = type.Namespace ?? string.Empty;

        // The one exception inside a forbidden prefix: CodeAnalysis carries attributes such as
        // [NotNullWhen], which describe a signature and confer no capability. Excluded by name so that
        // the exclusion is visible rather than implied by a narrower prefix.
        if (ns.StartsWith("System.Diagnostics.CodeAnalysis", StringComparison.Ordinal))
        {
            return false;
        }

        return ActingNamespaces.Any(prefix => ns.StartsWith(prefix, StringComparison.Ordinal));
    }

    private static bool IsProviderOrVendorAssembly(string assemblyName)
        => assemblyName.StartsWith("Nexus.Platform.Providers", StringComparison.Ordinal)
           || VendorNames.Any(v => assemblyName.Contains(v, StringComparison.OrdinalIgnoreCase));

    private static readonly string[] VendorNames =
    [
        "openai", "anthropic", "claude", "gpt", "deepseek", "gemini", "mistral", "llama", "ollama",
        "cohere", "bedrock", "vertex",
    ];

    private static bool IsPlatformAuthority(string value)
        => AiGovernanceAuthority.All.Contains(value, StringComparer.Ordinal);

    private static bool IsStaticStringCollection(Type type)
    {
        if (type == typeof(string))
        {
            return false;
        }

        if (type.IsArray)
        {
            return type.GetElementType() == typeof(string);
        }

        if (!type.IsGenericType)
        {
            return false;
        }

        var definition = type.GetGenericTypeDefinition();
        var arguments = type.GetGenericArguments();

        // Dictionaries count. A static "model id -> endpoint" map is the same hardcoded list wearing two
        // columns, and a detector that only saw one-column collections would miss it.
        if (definition == typeof(IDictionary<,>)
            || definition == typeof(IReadOnlyDictionary<,>)
            || definition == typeof(Dictionary<,>))
        {
            return arguments[0] == typeof(string) && arguments[1] == typeof(string);
        }

        if (definition != typeof(IEnumerable<>)
            && definition != typeof(IReadOnlyCollection<>)
            && definition != typeof(ICollection<>)
            && definition != typeof(IReadOnlyList<>)
            && definition != typeof(IList<>)
            && definition != typeof(List<>)
            && definition != typeof(HashSet<>)
            && definition != typeof(IReadOnlySet<>)
            && definition != typeof(ISet<>))
        {
            return false;
        }

        return arguments.All(a => a == typeof(string));
    }

    private static IEnumerable<string> AsStrings(object? value)
    {
        if (value is null)
        {
            yield break;
        }

        if (value is IEnumerable<string> strings)
        {
            foreach (var element in strings)
            {
                yield return element;
            }
        }
    }

    private static bool ReturnsAwaitable(Type returnType)
    {
        if (returnType == typeof(System.Threading.Tasks.Task)
            || returnType == typeof(System.Threading.Tasks.ValueTask))
        {
            return true;
        }

        if (!returnType.IsGenericType)
        {
            return false;
        }

        var definition = returnType.GetGenericTypeDefinition();

        return definition == typeof(System.Threading.Tasks.Task<>)
               || definition == typeof(System.Threading.Tasks.ValueTask<>);
    }
}
