using System.Reflection;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Core.Models;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W5G / F-01: the AI-side half of the ownership lock.
//
// The Platform-side test that used to hold this line
// (PlatformBoundaryTests.UsageMeter_IsOwnedByCoreModelInfrastructure) asserted three
// namespace facts, one of which locked InMemoryUsageMeter into Nexus.Platform.Core. F-01
// supersedes that, so the assertion could not simply be adapted - it had to move to the
// repository that now owns the type. Without this file the F-01 move would have NO
// continuous guard at all, and the two copies could silently coexist again.
//
// The assertions are written assembly-first, not namespace-first, on purpose. Namespaces were
// deliberately preserved through the move (HD-11), so several of these types still read
// Nexus.Platform.Core.Models / Nexus.Platform.Contracts.Models while being compiled into
// Nexus.Intelligence.Core. Asserting the namespace would therefore have proved nothing about
// ownership. The ASSEMBLY is what moved, so the assembly is what is asserted.
public sealed class ModelDomainOwnershipTests
{
    private const string AiHeadAssembly = "Nexus.Intelligence.Core";
    private const string PlatformContractPlane = "Nexus.Platform.Contracts";

    private static string AssemblyOf(Type type) => type.Assembly.GetName().Name!;

    // The five implementation/extension-point types F-01 moved. All AI-owned.
    [Fact]
    public void MovedModelDomainTypes_AreOwnedByTheAiHeadAssembly()
    {
        Assert.Equal(AiHeadAssembly, AssemblyOf(typeof(AggregatingModelCatalog)));
        Assert.Equal(AiHeadAssembly, AssemblyOf(typeof(RoutingModelGateway)));
        Assert.Equal(AiHeadAssembly, AssemblyOf(typeof(InMemoryUsageMeter)));
        Assert.Equal(AiHeadAssembly, AssemblyOf(typeof(INamedModelGateway)));
        Assert.Equal(AiHeadAssembly, AssemblyOf(typeof(IModelCatalogSource)));
    }

    // IModelCatalog is the sixth type F-01 moved, and the sharpest case: it is a CONTRACT,
    // but its semantics are AI-domain, so it leaves the Platform Contract Plane with the
    // implementations. If the next Nexus.Platform.Contracts release ever re-introduces it,
    // this test fails and names the reason.
    [Fact]
    public void IModelCatalog_IsOwnedByTheAiHead_NotThePlatformContractPlane()
    {
        Assert.Equal(AiHeadAssembly, AssemblyOf(typeof(IModelCatalog)));
    }

    // The other direction, asserted with equal force: the neutral contracts the AI Head
    // consumes across the PL-04 Contract Plane must still come from the Platform package.
    // Without this, the AI Head could quietly grow local copies of these and the neutrality
    // of the boundary would be gone with nothing failing.
    [Fact]
    public void NeutralModelContracts_AreStillConsumedFromThePlatformContractPlane()
    {
        Assert.Equal(PlatformContractPlane, AssemblyOf(typeof(IModelGateway)));
        Assert.Equal(PlatformContractPlane, AssemblyOf(typeof(IUsageMeter)));
        Assert.Equal(PlatformContractPlane, AssemblyOf(typeof(UsageRecord)));
        Assert.Equal(PlatformContractPlane, AssemblyOf(typeof(ModelDescriptor)));
        Assert.Equal(PlatformContractPlane, AssemblyOf(typeof(ModelQuery)));
    }

    // The duplicate-identity guard, stated directly against the shipped package rather than
    // against this repository's own source. A type that exists in two assemblies is the D-a
    // (silent DI split) / D-b (CS0104) hazard TASK 7 forbids, and "does it compile" cannot
    // detect it - a partial move compiles. This asks the loaded Platform.Contracts assembly
    // whether it ships IModelCatalog, so a re-release that re-adds it fails here.
    [Fact]
    public void PlatformContractPlane_MustNotShipTheMovedModelDomain()
    {
        var contractPlane = typeof(IUsageMeter).Assembly;

        string[] mustNotBeShipped =
        [
            "Nexus.Platform.Contracts.Models.IModelCatalog",
        ];

        foreach (var name in mustNotBeShipped)
        {
            Assert.Null(contractPlane.GetType(name, throwOnError: false));
        }
    }

    // Non-vacuity for the guard above: the same reflection call must be able to FIND a type
    // the contract plane definitely ships. If GetType returned null for everything - a
    // misconfigured load, a renamed assembly - the absence assertion would pass forever.
    [Fact]
    public void PlatformContractPlane_ShipsTheNeutralContracts_TheAbsenceCheckIsNotVacuous()
    {
        var contractPlane = typeof(IUsageMeter).Assembly;

        Assert.NotNull(contractPlane.GetType("Nexus.Platform.Contracts.Models.IUsageMeter", throwOnError: false));
        Assert.NotNull(contractPlane.GetType("Nexus.Platform.Contracts.Core.IQuotaPolicy", throwOnError: false));
        Assert.NotNull(contractPlane.GetType("Nexus.Platform.Contracts.Secrets.ISecretResolver", throwOnError: false));
    }
}
