using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Nexus.Intelligence.Api.DependencyInjection;
using Nexus.Intelligence.Api.Tooling;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Registry;
using Nexus.Intelligence.Core.Turns;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;
using Nexus.Platform.Core;
using Nexus.Platform.Providers.OpenAI;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7D TASKS 2, 3 and 6 as repository-level facts about the COMMITTED configuration.
//
// WHY THIS FILE EXISTS. W7D added three sections to appsettings.json - Agents, Tools and Prompts - and
// the claims those sections have to support are not about a value a test can call. They are claims about
// the state the estate ships in: that registering an agent makes it available and not approved, that a
// tool nobody classified cannot be reached, and that an instruction set is versioned before it is
// usable. Each is true on the day it is written and quietly false six months later, because an operator
// turning one on is exactly what the section is FOR.
//
// So each is checked from outside the code that implements it: by parsing the committed file and by
// composing the real registry the composition root composes. The behavioural suites in
// Nexus.Intelligence.Tests then prove the same gates on a fixture; this one proves them on the file.
//
// The claims the W7D directive words more strongly than this estate can support - per-item tenant
// scoping, and a caller's own classification assertion being verified - are stated where they arise in
// the behavioural suite rather than asserted here, because a boundary test that asserted a control that
// does not exist would be worse than no test at all.
public sealed class W7dRegistryConfigurationTests
{
    // The version shape a prompt's Version field has to have. Narrow on purpose: a prompt whose version
    // is "latest" or absent cannot be the artefact an audit record reproduces an execution from.
    private static readonly Regex PromptVersionShape = new(
        @"^\d+\.\d+\.\d+$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    // The agents the committed configuration registers. Named rather than counted, because a section
    // that silently lost an entry would still be "non-empty".
    private static readonly string[] RegisteredAgentIds = ["developer", "research", "architect", "reviewer"];

    // ---------------------------------------------------------------------------------------------
    // TASK 2: the committed agent registry is a set of facts about agents, none of which may act.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheCommittedAgentSection_RegistersEveryAgentAndApprovesNone()
    {
        // TASK 2's "do not hardcode permanent agent definitions into business logic", stated as a
        // property of the committed file. Every identifier the turn path's agent selection can name has
        // to appear here, because the alternative - an enum in the assembly - is a set of agents that
        // changes only by shipping a build.
        var configuration = ReadCommittedConfiguration();

        Assert.All(
            RegisteredAgentIds,
            agentId => Assert.Contains(configuration.Agents, entry => entry.AgentId == agentId));

        Assert.All(configuration.Agents, agent =>
        {
            // Registered is not approved, and not enabled. These three lines are the whole fail-closed
            // posture: the entry states the agent exists, its remit, and that nobody has cleared it.
            Assert.False(agent.Enabled, $"Agent '{agent.AgentId}' is committed enabled.");
            Assert.Equal("Unregistered", agent.Approval);
            Assert.Null(agent.ApprovedBy);

            // No tool grant, and no side-effect ceiling raised above none. An agent's authority is a
            // grant of specific work, so the committed state is an agent cleared for nothing.
            Assert.Empty(agent.AllowedToolIds);
            Assert.Equal("None", agent.MaxSideEffect);

            // Narrowest classification, so the entry cannot be read as clearing the agent for content
            // by default when its operator turns it on.
            Assert.Equal("Public", agent.MaxClassification);

            // An agent that names no instruction set and declares no capability is an entry that cannot
            // be reviewed: there is nothing to say what it would do. Both are required facts, not
            // optional decoration.
            Assert.False(string.IsNullOrWhiteSpace(agent.PromptId), $"Agent '{agent.AgentId}' names no prompt.");
            Assert.NotEmpty(agent.AllowedCapabilities);
            Assert.False(string.IsNullOrWhiteSpace(agent.GovernanceRationale));
        });

        // NON-VACUITY: every agent above was examined. An empty section would satisfy Assert.All.
        Assert.NotEmpty(configuration.Agents);

        // ...and the section is not merely a copy of one entry.
        Assert.Equal(
            RegisteredAgentIds.Length,
            configuration.Agents.Select(agent => agent.AgentId).Distinct(StringComparer.Ordinal).Count());
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 6: the committed instruction sets are versioned, owned and unapproved.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheCommittedPromptSection_VersionsAndOwnsEveryInstructionSet_AndApprovesNone()
    {
        // TASK 6's "runtime components should reference PromptId / InstructionId / Version rather than
        // burying long operational prompts in routing/provider code". A buried prompt cannot be
        // versioned; a registered one can be, and this is the assertion that it was.
        var configuration = ReadCommittedConfiguration();

        Assert.NotEmpty(configuration.Prompts);

        Assert.All(configuration.Prompts, prompt =>
        {
            Assert.False(string.IsNullOrWhiteSpace(prompt.PromptId));

            // Versioned. A prompt applied with no version could not be reproduced from its own audit
            // record, and the governance engine refuses one - so a missing version here is a prompt that
            // refuses every turn that names it, discovered in production rather than in review.
            Assert.Matches(PromptVersionShape, prompt.Version!);

            // Owned and justified. Both are required fields in the registry because a prompt is the
            // artefact that most directly steers the model and the one most likely to be edited in
            // place; an editor with nobody to ask is how prompt text drifts.
            Assert.False(string.IsNullOrWhiteSpace(prompt.Owner));
            Assert.False(string.IsNullOrWhiteSpace(prompt.Rationale));

            // The frame is the artefact. An enabled prompt with an empty frame would apply nothing and
            // report that it had applied something.
            Assert.False(string.IsNullOrWhiteSpace(prompt.SystemFrame));

            // Registered, not approved, and not enabled - the same posture the agents carry, for the
            // same reason.
            Assert.False(prompt.Enabled, $"Prompt '{prompt.PromptId}' is committed enabled.");
            Assert.Equal("Unregistered", prompt.Approval);
        });

        // The live path's own instruction set is among them, so the turn a Product sends resolves its
        // frame through the registry rather than through a literal.
        Assert.Contains(configuration.Prompts, prompt => prompt.PromptId == AiPrompts.ConversationTurn);

        // CONTROL: the version shape is a real constraint rather than a pattern nothing can fail. Both
        // halves are asserted, because a regex that matched everything and a regex that matched nothing
        // would each satisfy only one of them.
        Assert.Matches(PromptVersionShape, "1.0.0");
        Assert.DoesNotMatch(PromptVersionShape, "latest");
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 3: the committed tool section declares no tool, and an unclassified tool cannot be reached.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheCommittedToolSection_DeclaresNoTool_SoNoToolCanBeClassified()
    {
        // AN EMPTY SECTION IS THE COMMITTED STATE, and it is a decision rather than an omission. The
        // runtime tool catalogue offers nothing, so the estate has no tool whose effect, caller scope
        // and data scope anyone has assessed. Declaring none is therefore the honest entry: it says the
        // estate has classified no tool, which is a different statement from declaring a tool with an
        // empty permission set and hoping the two are read the same way.
        var configuration = ReadCommittedConfiguration();
        var registry = new ConfiguredAiRegistry(configuration);

        Assert.Empty(configuration.Tools);

        // The consequence, which is the part that matters: because no tool is declared, the registry
        // classifies none, so a tool offered by the Platform catalogue is unclassified - and an
        // unclassified tool is refused by default rather than permitted by omission.
        Assert.Empty(registry.GovernanceRules);

        Assert.False(registry.TryGetTool("tool.anything", out var tool));
        Assert.Null(tool);

        // NON-VACUITY: the tool lookup is a real lookup on a real registry, so `TryGetTool` returning
        // false above is the absence of a declaration and not a method that always answers false. The
        // same call against the same file with one entry added finds it.
        var declaredConfiguration = ReadCommittedConfiguration();
        declaredConfiguration.Tools =
        [
            new AiToolConfigurationEntry
            {
                ToolId = "tool.anything",
                DisplayName = "Anything",
                Purpose = "The control for the assertion above.",
                SideEffect = "Read",
                Enabled = true,
                GovernanceState = "Approved",
                Rationale = "W7D boundary control.",
            },
        ];

        var declared = new ConfiguredAiRegistry(declaredConfiguration);

        Assert.Single(declared.GovernanceRules);
        Assert.True(declared.TryGetTool("tool.anything", out var found));
        Assert.Equal("tool.anything", found!.ToolId);
    }

    // ---------------------------------------------------------------------------------------------
    // The composition: the committed file parses, composes, and refuses a turn at every named gate.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheCommittedRegistry_ResolvesWhatItDeclares_AndRefusesATurnAtEveryGate()
    {
        // This test is also the parse check. The Agents, Tools and Prompts sections are new, and a
        // typo in one of them would not fail any behavioural test in this repository - the fixtures
        // build their own registries. Composing the committed file is what makes the edit itself
        // covered.
        var configuration = ReadCommittedConfiguration();
        var registry = new ConfiguredAiRegistry(configuration);

        // It declares what it says it declares: the four resource kinds resolve by the identifiers the
        // file uses, so the sections were bound rather than skipped.
        Assert.True(registry.TryGetAgent("developer", out var agent));
        Assert.NotNull(agent);
        Assert.True(registry.TryGetPrompt(AiPrompts.ConversationTurn, out var prompt));
        Assert.Equal("1.0.0", prompt!.Version);
        Assert.True(registry.TryGetModel("openai:gpt-4.1", out var model));
        Assert.NotNull(model);
        Assert.True(registry.TryGetProvider("openai", out var provider));
        Assert.NotNull(provider);

        // A representative turn: the shape the live path sends, naming the agent the turn path selects,
        // the instruction set that agent carries, and the model and provider the file registers.
        var decision = Evaluate(registry);

        Assert.True(decision.IsBlocked, decision.Reason);

        // Every approval gate refuses, from one evaluation. Each stage records its own rule and the
        // decision composes most-restrictively, so the applied list carries all three rather than only
        // the most severe - which is what lets a single evaluation stand for all of them.
        Assert.Contains(AiGovernanceRules.ModelNotApproved, decision.RulesApplied);
        Assert.Contains(AiGovernanceRules.AgentNotApproved, decision.RulesApplied);
        Assert.Contains(AiGovernanceRules.PromptNotApproved, decision.RulesApplied);

        // NON-VACUITY: the rules above are not a list the engine emits for every refusal. It emits the
        // allowed rule when nothing fires, and the following control changes exactly one field - the
        // developer agent's approval status - and removes the agent rule while leaving the other two.
        // So the three are answers about three independent records rather than one refusal reported
        // three ways, and the model and prompt gates are still reached.
        var approvedConfiguration = ReadCommittedConfiguration();

        approvedConfiguration.Agents.Single(entry => entry.AgentId == "developer").Approval = "Approved";

        var controlled = Evaluate(new ConfiguredAiRegistry(approvedConfiguration));

        Assert.DoesNotContain(AiGovernanceRules.AgentNotApproved, controlled.RulesApplied);
        Assert.Contains(AiGovernanceRules.ModelNotApproved, controlled.RulesApplied);
        Assert.Contains(AiGovernanceRules.PromptNotApproved, controlled.RulesApplied);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 7: the composition root wires the live pipeline onto the governed path, and only onto it.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheCompositionRoot_WiresTheLivePipelineOntoTheGovernedPath_AndNoOther()
    {
        // TASK 7's "TurnPipeline must NOT choose provider directly; choose model directly; access
        // provider secrets; bypass governance; invoke a second legacy routing path". Two halves, and
        // neither is a property of the pipeline's code alone.
        //
        // The first half is that the container built from the COMMITTED configuration resolves the live
        // pipeline at all. A registration that was removed while its interface stayed in use fails here
        // rather than at the first turn in an environment.
        var configuration = new ConfigurationBuilder()
            .AddJsonFile(Path.Combine(ApiProjectDirectory, "appsettings.json"), optional: false)
            .Build();

        // The lines below mirror Program.cs rather than working around it. Each was found by this test
        // failing to resolve the pipeline from the two extension methods alone, which is itself the
        // finding: AddNexusIntelligence does NOT compose a resolvable TurnPipeline by itself. It expects
        // a host to supply the Platform-side ports.
        //
        //   AddLogging          Program.cs builds a WebApplicationBuilder, which registers logging, and
        //                       the built-in runtime agents take an ILogger.
        //   IToolCatalog        Registered by the HOST, because the Platform tool catalogue is a
        //   IToolGateway        Platform concern the host supplies. Nexus.Platform.Tools has no governed
        //                       tool registry yet, so the host's own empty implementations are used.
        //   TimeProvider        InMemoryMemoryStore takes one; the host registers TimeProvider.System.
        //   AddOpenAIModelPro.. Supplies IModelCatalog, which AiRoleResolver reads. Mirrors the host's
        //                       registration; nothing here resolves a credential or reaches a network.
        //
        // None of these is a W7D change and all of them predate this lane. They are supplied so that the
        // resolution below is the host's composition - a test that resolved only the services that need
        // nothing from the host would be asserting a composition nobody runs.
        using var serviceProvider = new ServiceCollection()
            .AddLogging()
            .AddSingleton<IToolCatalog, EmptyToolCatalog>()
            .AddSingleton<IToolGateway, EmptyToolGateway>()
            .AddSingleton(TimeProvider.System)
            .AddNexusPlatform(configuration)
            .AddOpenAIModelProvider(configuration.GetSection("Platform:Providers"))
            .AddNexusIntelligence(configuration)
            .BuildServiceProvider();

        var pipeline = serviceProvider.GetRequiredService<ITurnPipeline>();
        Assert.IsType<TurnPipeline>(pipeline);

        // ...and that the execution seam it calls into is the governed one, not a second pipeline that
        // happens to satisfy the interface.
        var execution = serviceProvider.GetRequiredService<IGovernedTurnExecution>();
        Assert.IsType<GovernedTurnExecution>(execution);

        // The second half is structural, and it is asserted rather than commented because a comment is
        // exactly what a future edit does not read. The pipeline's dependencies are its capability set:
        // a type it does not hold is a thing it cannot do, whatever its methods say.
        var dependencies = typeof(TurnPipeline)
            .GetConstructors()
            .SelectMany(constructor => constructor.GetParameters())
            .Select(parameter => parameter.ParameterType)
            .ToArray();

        // It holds the governed seam. This is also the NON-VACUITY check for everything below: the
        // reflection is reading a real constructor rather than an empty parameter list.
        Assert.Contains(typeof(IGovernedTurnExecution), dependencies);
        Assert.NotEmpty(dependencies);

        // It holds nothing that could reach a provider on its own, and no selector that could choose
        // one. The three ports the pipeline used before W7D are named literally; the selector is matched
        // by name because the type no longer exists to name, and a scan that could only name deleted
        // types would stop guarding the moment one came back.
        Assert.DoesNotContain(typeof(IModelStep), dependencies);
        Assert.DoesNotContain(typeof(IToolLoop), dependencies);
        Assert.DoesNotContain(typeof(IModelGateway), dependencies);

        Assert.DoesNotContain(
            dependencies,
            dependency => dependency.Name.Contains("ModelSelector", StringComparison.Ordinal)
                || dependency.Name.Contains("ModelGateway", StringComparison.Ordinal)
                || dependency.Name.Contains("ToolGateway", StringComparison.Ordinal));

        // CONTROL, applied to the same array: the forbidden set is not simply a list nothing can be a
        // member of. A type that IS one of those ports is found by the same predicate, so the absences
        // above are the pipeline's shape and not the scan's blindness.
        Type[] hypothetical = [typeof(IModelStep), typeof(IToolLoop), typeof(IGovernedTurnExecution)];

        Assert.Contains(hypothetical, dependency => dependency == typeof(IModelStep));
        Assert.Contains(
            hypothetical,
            dependency => dependency.Name.Contains("Tool", StringComparison.Ordinal));
        Assert.DoesNotContain(
            [typeof(IGovernedTurnExecution)],
            dependency => dependency == typeof(IModelStep));
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    /// <summary>The committed configuration, as the composition root would bind it.</summary>
    private static AiRegistryConfiguration ReadCommittedConfiguration()
        => new ConfigurationBuilder()
            .AddJsonFile(Path.Combine(ApiProjectDirectory, "appsettings.json"), optional: false)
            .Build()
            .GetSection(AiRegistryConfiguration.SectionName)
            .Get<AiRegistryConfiguration>()
            ?? new AiRegistryConfiguration();

    /// <summary>Evaluates one representative request against a policy over the given registry.</summary>
    private static AiGovernanceDecision Evaluate(ConfiguredAiRegistry registry)
        => new DeterministicAiGovernanceEvaluator(Policy(registry)).Evaluate(
            new AiGovernanceEvaluationRequest
            {
                RequestId = "req-w7d-committed",
                Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
                Requester = new AiRequesterIdentity
                {
                    Head = CallingHead.Ai,
                    PrincipalId = "principal-w7d",
                    PermissionScope = AiPermissionScope.None,
                    DataScopes = ["tenant:acme"],
                },
                Classification = DataClassification.Public,
                ContextClassifications = [],
                Destination = AiDestinationClass.Local,
                Execution = AiExecutionPolicy.Default,
                Tools = ToolPermissionProfile.None,
                RequestedToolIds = [],
                ModelId = "openai:gpt-4.1",
                ProviderId = "openai",
                AgentId = "developer",
                PromptId = AiPrompts.ConversationTurn,
                PromptVersion = "1.0.0",
                CorrelationId = "corr-w7d-committed",
            },
            AiPlatformGovernanceAttestation.NotApplicable);

    /// <summary>
    /// The governance policy the composition root builds over a configured registry.
    /// </summary>
    /// <remarks>
    /// Mirrors <c>IntelligenceServiceCollectionExtensions</c>. The tool rules are projected from the
    /// registry rather than restated, which is W7D TASK 3's "one source" property: the policy table and
    /// the tool registry cannot describe the same tool differently because there is one table.
    /// </remarks>
    private static AiGovernancePolicy Policy(ConfiguredAiRegistry registry) => new()
    {
        Dependencies = AiDependencyRegistry.Empty,
        Capabilities = AiCapabilityRegister.Bootstrap(),
        Exposure = DataExposurePolicy.Default(),
        Register = new RegistryAiGovernanceRegister(registry, registry, registry, registry),
        Budgets = [],
        RequireBudgetRuleForPricedExecution = false,
        Tools = registry.GovernanceRules,
        Escalations = [],
    };

    private static string RepositoryRoot { get; } = FindRepositoryRoot();

    private static string ApiProjectDirectory => Path.Combine(RepositoryRoot, "src", "Nexus.Intelligence.Api");

    /// <summary>Walks up from the test assembly until the repository root is found.</summary>
    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);

        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "Nexus.Intelligence.slnx")))
        {
            directory = directory.Parent;
        }

        Assert.NotNull(directory);

        return directory!.FullName;
    }
}
