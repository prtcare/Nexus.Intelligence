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

    // W4R-06: the forbidden-name set for Intelligence_MustNotReference_Products is exposed so the
    // regression fixture (BoundaryRuleFixtureProofTests) proves the SHIPPED list, not a copy of it.
    // NetArchTest 1.3.2 matches a token as a WHOLE-NAMESPACE-SEGMENT prefix of the dependency's full
    // type name, case-sensitively - measured, see the W4R-06 conformance inventory. A token
    // therefore has to name a real namespace ROOT; a bare word that is only ever a leaf segment can
    // never match anything.
    internal static readonly string[] BannedProductNamespaces =
    [
        // The product tree ("Nexus.Products.Chat.*" and the other product assemblies).
        "Nexus.Products",

        // The product-scope trunk. CHG-20260827-001 relocated Workspace/Project out of the Chat
        // product and into the shared Layer 06 scope trunk, which ships under the
        // Nexus.ProductCore.* namespace root (Nexus.ProductCore.Contracts, Nexus.ProductCore.Scope).
        // The superseded "Nexus.Products" token does not match it: the segment is "ProductCore", not
        // "Products".
        "Nexus.ProductCore"
    ];

    // The token list this rule shipped with before W4R-06. Retained ONLY as the control arm of
    // BoundaryRuleFixtureProofTests; no production rule uses it.
    internal static readonly string[] SupersededProductTokens = ["Nexus.Products"];

    // W4R-06: the vendor-isolation token set, exposed as a constant so the regression fixture
    // (BoundaryRuleFixtureProofTests) proves the SHIPPED list rather than a copy of it.
    //
    // RECONCILED AT W7A.1. W4R-06 corrected this list for a rule named
    // Intelligence_MustNotReference_VendorSdks, which asserted over ALL Nexus.Intelligence.*
    // assemblies. W6/LaneB (fa650e6) RETIRED that rule under NEXUS V3 and narrowed the invariant to
    // Nexus.Intelligence.Contracts, where this list now applies. W4R-06's corrected list is
    // therefore NOT carried: it was written for a rule that no longer exists, and adopting it here
    // would silently DROP coverage the shipping Contracts rule already has - DeepSeek, Mistral,
    // Ollama, Google.GenerativeAI, Microsoft.Extensions.AI and Microsoft.SemanticKernel are all in
    // the shipped list and in none of W4R-06's. A merge must not change a rule's coverage.
    //
    // W4R-06's durable contribution is the MEASUREMENT, retained below because it is what makes the
    // NEXUS-owned wrapper entries load-bearing, and the constant-extraction pattern itself.
    internal static readonly string[] BannedVendorNamespaces =
    [
        // NEXUS-owned provider wrappers. This is the namespace a NEXUS assembly actually reaches
        // when it takes an OpenAI/Anthropic dependency: measured on the real build,
        // Nexus.Intelligence.Api.dll references Nexus.Platform.Providers.OpenAI.* and NOT ONE bare
        // "OpenAI"-rooted type. A bare token cannot match the wrapper - the wrapper's full type name
        // starts with the segment "Nexus", never with the segment "OpenAI". This single entry covers
        // both relocated wrappers, because NetArchTest matches a token as a whole-namespace-segment
        // prefix.
        "Nexus.Platform.Providers",

        // Genuine vendor SDK root namespaces.
        "OpenAI",
        "Azure.AI",
        "Anthropic",
        "DeepSeek",
        "Mistral",
        "Ollama",
        "Google.GenerativeAI",
        "Microsoft.Extensions.AI",
        "Microsoft.SemanticKernel"
    ];

    // The token list W4R-06 replaced, retained ONLY as the control arm of
    // BoundaryRuleFixtureProofTests. Two defects are recorded there and both are real: the bare
    // "OpenAI" token cannot match the NEXUS provider wrapper (the fact the fixture proves), and the
    // bare "Dataverse" token could never match anything at all, because every real Dataverse type
    // lives under Microsoft.Xrm.*.
    internal static readonly string[] SupersededBareVendorTokens =
    [
        "OpenAI", "Azure", "Dataverse", "Microsoft.PowerPlatform.Dataverse", "Microsoft.Xrm"
    ];

    // Rule (NEXUS_ARCHITECTURE_V2.md section 2.3): no type in any Nexus.Intelligence.* assembly may
    // depend on a product type. DEPENDENCY_RULES.md Rule 5 states the same boundary as "no
    // Nexus.Intelligence.* assembly may reference any Nexus.Products.* or Nexus.Experience.*
    // assembly"; the product tree ships as Nexus.Products.* today, and the relocated scope trunk
    // ships as Nexus.ProductCore.*.
    [Fact]
    public void Intelligence_MustNotReference_Products()
    {
        var result = Types.InAssemblies(AllIntelligenceAssemblies)
            .ShouldNot()
            .HaveDependencyOnAny(BannedProductNamespaces)
            .GetResult();

        Assert.True(
            result.IsSuccessful,
            $"[Intelligence_MustNotReference_Products] No type in any Nexus.Intelligence.* assembly may depend on a " +
            $"product type (forbidden roots: {string.Join(", ", BannedProductNamespaces)}). See {DocReference}. " +
            $"Offending types: {Describe(result.FailingTypeNames)}");
    }

    // RETIRED under NEXUS V3 (W6-02). The former rule asserted that no OpenAI/Azure/Dataverse type
    // could appear ANYWHERE in Nexus.Intelligence.*, on the V2 premise that "vendor SDKs are
    // Platform's business only". V3 inverts that premise: the AI Head is now the owner of provider
    // routing, model selection, provider adapters and failover, and it holds
    // src\Nexus.Platform.Providers.OpenAI as a sibling project with a real OpenAI PackageReference.
    // The rule therefore forbade the AI Head from doing the job it now exists to do, and it passed
    // only by accident - Nexus.Intelligence.Api reaches the provider through the DI extension surface
    // (AddOpenAIModelProvider), so NetArchTest resolved no "OpenAI" type-level dependency.
    //
    // The V3 invariant is narrower and lives where it actually matters: Nexus.Intelligence.Contracts
    // is the ONLY Nexus.Intelligence.* artifact a Product may reference (see W6-02), so it is the
    // assembly that must never leak a vendor type or a provider implementation. The Product-side
    // reference-graph rule that enforces the consumer end of this boundary lives in the product repos:
    //   Products\Experience\tests\Nexus.Products.Chat.Architecture.Tests\VendorBoundaryGuardTests.cs
    //   Products\Developer\tests\Nexus.Developer.Core.Tests\VendorBoundaryGuardTests.cs
    [Fact]
    public void Contracts_MustNotExpose_VendorSdksOrProviderImplementations()
    {
        var result = Types.InAssembly(ContractsAssembly)
            .ShouldNot()
            .HaveDependencyOnAny(BannedVendorNamespaces)
            .GetResult();

        Assert.True(
            result.IsSuccessful,
            $"[Contracts_MustNotExpose_VendorSdksOrProviderImplementations] {VendorBoundaryRule} " +
            $"Offending types: {Describe(result.FailingTypeNames)}");
    }

    private const string VendorBoundaryRule =
        "NEXUS V3 / W6-02: Nexus.Intelligence.Contracts is the only Nexus.Intelligence.* artifact a Product may " +
        "reference, so it must expose nothing but provider-neutral DTOs and capability contracts. Vendor SDK types " +
        "and provider implementation assemblies belong to the AI Head's implementation assemblies, which products " +
        "reach over HTTP/API or through neutral capability contracts.";

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
