using System.Reflection;
using NetArchTest.Rules;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

public sealed class BoundaryRuleTests
{
    private const string DocReference = "NEXUS_ARCHITECTURE_V2.md section 2.3";

    private static readonly Assembly ContractsAssembly = typeof(Nexus.Intelligence.Contracts.IntelligenceTurnRequest).Assembly;
    private static readonly Assembly CoreAssembly = typeof(Nexus.Intelligence.Core.Turns.TurnPipeline).Assembly;
    private static readonly Assembly ContextAssembly = typeof(Nexus.Intelligence.Context.Ranking.KeywordContextRanker).Assembly;
    private static readonly Assembly AgentsAssembly = typeof(Nexus.Intelligence.Agents.AgentRegistry).Assembly;
    private static readonly Assembly MemoryAssembly = typeof(Nexus.Intelligence.Memory.InMemoryMemoryStore).Assembly;
    private static readonly Assembly ApiAssembly = typeof(Nexus.Intelligence.Api.Endpoints.TurnsEndpoints).Assembly;

    private static readonly Assembly[] AllIntelligenceAssemblies =
    [
        ContractsAssembly, CoreAssembly, ContextAssembly, AgentsAssembly, MemoryAssembly, ApiAssembly
    ];

    // Rule (NEXUS_ARCHITECTURE_V2.md section 2.3): Nexus.Intelligence.Contracts must depend on
    // nothing but the framework. Products consume this package and must never see IModelGateway.
    [Fact]
    public void Contracts_MustNotReference_Platform()
    {
        var result = Types.InAssembly(ContractsAssembly)
            .ShouldNot()
            .HaveDependencyOnAny("Nexus.Platform")
            .GetResult();

        Assert.True(
            result.IsSuccessful,
            $"[Contracts_MustNotReference_Platform] Nexus.Intelligence.Contracts must depend on nothing but the " +
            $"framework - products consume this package and must never see IModelGateway. See {DocReference}. " +
            $"Offending types: {Describe(result.FailingTypeNames)}");
    }

    // Rule (NEXUS_ARCHITECTURE_V2.md section 2.3): no type in any Nexus.Intelligence.* assembly may
    // depend on a Nexus.Products.* type.
    [Fact]
    public void Intelligence_MustNotReference_Products()
    {
        var result = Types.InAssemblies(AllIntelligenceAssemblies)
            .ShouldNot()
            .HaveDependencyOnAny("Nexus.Products")
            .GetResult();

        Assert.True(
            result.IsSuccessful,
            $"[Intelligence_MustNotReference_Products] No type in any Nexus.Intelligence.* assembly may depend on a " +
            $"Nexus.Products.* type. See {DocReference}. Offending types: {Describe(result.FailingTypeNames)}");
    }

    // Rule (NEXUS_ARCHITECTURE_V2.md section 2.3): no OpenAI, Azure or Dataverse types anywhere in
    // Nexus.Intelligence.*. Vendor SDKs are Platform's business only.
    [Fact]
    public void Intelligence_MustNotReference_VendorSdks()
    {
        var result = Types.InAssemblies(AllIntelligenceAssemblies)
            .ShouldNot()
            .HaveDependencyOnAny("OpenAI", "Azure", "Dataverse", "Microsoft.PowerPlatform.Dataverse", "Microsoft.Xrm")
            .GetResult();

        Assert.True(
            result.IsSuccessful,
            $"[Intelligence_MustNotReference_VendorSdks] No OpenAI, Azure or Dataverse types may appear anywhere in " +
            $"Nexus.Intelligence.*. See {DocReference}. Offending types: {Describe(result.FailingTypeNames)}");
    }

    // Rule (NEXUS_ARCHITECTURE_V2.md section 2.3): no type named Workspace, Project, Conversation,
    // ConversationMessage, Knowledge, WorkItem, Artifact, Branch, Snapshot, Session or Adr may appear
    // anywhere in Nexus.Intelligence.*. Whole-name match only - KnowledgeCandidate and
    // PersistenceHintKind are legitimate and must not trip this.
    [Fact]
    public void Intelligence_MustNotContain_ProductTypeNames()
    {
        var bannedNames = new[]
        {
            "Workspace", "Project", "Conversation", "ConversationMessage", "Knowledge",
            "WorkItem", "Artifact", "Branch", "Snapshot", "Session", "Adr"
        };

        var pattern = $"^({string.Join('|', bannedNames)})$";

        var offending = Types.InAssemblies(AllIntelligenceAssemblies)
            .That()
            .HaveNameMatching(pattern)
            .GetTypes()
            .ToArray();

        Assert.True(
            offending.Length == 0,
            $"[Intelligence_MustNotContain_ProductTypeNames] No type named {string.Join(", ", bannedNames)} may " +
            $"appear anywhere in Nexus.Intelligence.*. See {DocReference}. " +
            $"Offending types: {string.Join(", ", offending.Select(t => t.FullName))}");
    }

    private static string Describe(IEnumerable<string>? failingTypeNames) =>
        failingTypeNames is null || !failingTypeNames.Any() ? "(none)" : string.Join(", ", failingTypeNames);
}
