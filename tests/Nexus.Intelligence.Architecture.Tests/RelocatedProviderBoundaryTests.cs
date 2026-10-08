using System.Linq;
using System.Reflection;
using NetArchTest.Rules;
using Nexus.Platform.Contracts.Core;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W5G / F-01: RELOCATED from Nexus.Platform.Architecture.Tests/PlatformBoundaryTests.cs.
//
// These four assertions were scoped to Nexus.Platform.Providers.OpenAI, which moved into
// this repository, so they could not stay in Platform - they no longer compiled there. They
// were moved rather than dropped because two of them are the only continuous guard on the
// provider's Product-Core and GOVERNANCE independence, and two are the positive companions
// that stop the negative tests from passing vacuously. A ShouldNot assertion on a namespace
// nothing references passes trivially; the estate has paid for that mistake repeatedly.
//
// What changed in the move, and only this: the assembly is resolved by
// typeof(OpenAIModelGateway) inside THIS repository, and the "Core" the provider may
// legitimately depend on is now consumed as a pinned Nexus.Platform.Contracts package from
// the cross-Head contract boundary rather than as a sibling project. The relationships
// asserted are identical.
public sealed class RelocatedProviderBoundaryTests
{
    private static Assembly ProviderAssembly => typeof(Nexus.Platform.Providers.OpenAI.OpenAIModelGateway).Assembly;

    // Original: OpenAiProviderAssembly_MustNotHaveTypeDependencyOn_ProductCoreOwnedNamespaces
    [Fact]
    public void OpenAiProviderAssembly_MustNotHaveTypeDependencyOn_ProductCoreOwnedNamespaces()
    {
        var result = Types.InAssembly(ProviderAssembly)
            .ShouldNot()
            .HaveDependencyOnAny("Nexus.Platform.Core.ProductCore", "Nexus.Platform.Contracts.ProductCore", "Nexus.ProductCore")
            .GetResult();

        Assert.True(
            result.IsSuccessful,
            "AI provider has a forbidden type-level dependency on Product-Core-owned code: " +
            string.Join(", ", result.FailingTypeNames ?? []));
    }

    // Original: OpenAiProviderAssembly_MustNotHaveTypeDependencyOn_GovernanceOwnedNamespaces
    [Fact]
    public void OpenAiProviderAssembly_MustNotHaveTypeDependencyOn_GovernanceOwnedNamespaces()
    {
        var result = Types.InAssembly(ProviderAssembly)
            .ShouldNot()
            .HaveDependencyOnAny("Nexus.Governance")
            .GetResult();

        Assert.True(
            result.IsSuccessful,
            "AI provider has a forbidden type-level dependency on Governance-owned code: " +
            string.Join(", ", result.FailingTypeNames ?? []));
    }

    // Original: OpenAiProvider_MayLegitimatelyDependOn_Core
    //
    // Direct/structural rather than a namespace-aggregate NetArchTest check, deliberately:
    // NetArchTest's namespace-scoped Should().HaveDependencyOnAny(...) requires EVERY type in
    // the matched namespace to satisfy the dependency, and the provider's four types do not
    // all take an IQuotaPolicy. The aggregate form failed for that reason when it was first
    // written (see architecture/NEXUS_V2_EXECUTION_BATCH_06_REPORT.md) and was corrected to
    // this shape. The correction was carried over with the move.
    [Fact]
    public void OpenAiProvider_MayLegitimatelyDependOn_Core()
    {
        var constructor = typeof(Nexus.Platform.Providers.OpenAI.OpenAIModelGateway)
            .GetConstructors()
            .Single();

        var hasQuotaPolicyParameter = constructor.GetParameters()
            .Any(p => p.ParameterType == typeof(IQuotaPolicy));

        Assert.True(
            hasQuotaPolicyParameter,
            "Expected OpenAIModelGateway's constructor to take an IQuotaPolicy parameter.");

        // The contract must still resolve from the Platform Contract Plane package. If the
        // provider had grown a local copy of IQuotaPolicy, the parameter check above would
        // still pass while the neutral boundary was silently duplicated.
        Assert.Equal("Nexus.Platform.Contracts", typeof(IQuotaPolicy).Assembly.GetName().Name);
        Assert.Equal("Nexus.Platform.Contracts.Core", typeof(IQuotaPolicy).Namespace);
    }

    // Original: OpenAiProvider_MayLegitimatelyEmitThrough_CoreAuditBoundary
    [Fact]
    public void OpenAiProvider_MayLegitimatelyEmitThrough_CoreAuditBoundary()
    {
        var constructor = typeof(Nexus.Platform.Providers.OpenAI.OpenAIModelGateway)
            .GetConstructors()
            .Single();

        var hasAuditLogParameter = constructor.GetParameters()
            .Any(p => p.ParameterType == typeof(IAuditLog));

        Assert.True(
            hasAuditLogParameter,
            "Expected OpenAIModelGateway's constructor to take an IAuditLog parameter.");

        Assert.Equal("Nexus.Platform.Contracts", typeof(IAuditLog).Assembly.GetName().Name);
        Assert.Equal("Nexus.Platform.Contracts.Core", typeof(IAuditLog).Namespace);
    }
}
