using System.Reflection;
using NetArchTest.Rules;
using Xunit;

// W4R-06 regression proof for the two rules that shipped with tokens which could not match the
// dependency they named.
//
// Each fixture below is a DELIBERATELY VIOLATING type: it genuinely depends on a type whose
// namespace is the one the corresponding boundary rule claims to forbid. The guard tests run the
// rule's SUPERSEDED token list and its SHIPPED token list over the same fixture, so the proof is
// self-contained and does not depend on the state of the real product assemblies:
//
//   superseded list -> the rule PASSES the fixture  (the check could not fail)
//   shipped list    -> the rule FAILS  the fixture  (the check can fail)
//
// The fixture types live in this test assembly. NetArchTest.Rules 1.3.2 resolves dependencies from
// IL and sees references between types of the same assembly - the same mechanism the W4R-06
// inventory measured against the real build.
namespace Nexus.Platform.Providers.OpenAI
{
    // Mimics the real Nexus.Platform.Providers.OpenAI.OpenAIServiceCollectionExtensions: the SDK
    // wrapper's full type name starts with the namespace segment "Nexus", never with "OpenAI".
    internal sealed class FixtureNexusProviderWrapper
    {
        internal static string Marker => "fixture-nexus-provider-wrapper";
    }
}

namespace Nexus.ProductCore.Contracts
{
    // Mimics the real Nexus.ProductCore.Contracts.ScopeKind relocated to the Layer 06 scope trunk.
    internal sealed class FixtureProductCoreContract
    {
        internal static string Marker => "fixture-product-core-contract";
    }
}

namespace Nexus.Intelligence.Architecture.Tests.Fixtures
{
    // Depends only on the NEXUS provider wrapper - exactly the coupling the real
    // Nexus.Intelligence.Api has today.
    internal static class FixtureNexusProviderWrapperConsumer
    {
        internal static string Use() => global::Nexus.Platform.Providers.OpenAI.FixtureNexusProviderWrapper.Marker;
    }

    // Depends only on the product-scope trunk root - the coupling the superseded "Nexus.Products"
    // token cannot name.
    internal static class FixtureProductCoreConsumer
    {
        internal static string Use() => global::Nexus.ProductCore.Contracts.FixtureProductCoreContract.Marker;
    }
}

namespace Nexus.Intelligence.Architecture.Tests
{
    public sealed class BoundaryRuleFixtureProofTests
    {
        private static Assembly FixtureAssembly => typeof(Fixtures.FixtureNexusProviderWrapperConsumer).Assembly;

        /// <summary>
        /// Runs the supplied forbidden-name list over the fixture assembly. The fixture assembly
        /// contains nothing else that touches either forbidden root, so a pass means "the list
        /// cannot see the violation".
        /// </summary>
        private static TestResult RunFixtureRule(string[] forbiddenNamespaces)
        {
            return Types.InAssembly(FixtureAssembly)
                .ShouldNot()
                .HaveDependencyOnAny(forbiddenNamespaces)
                .GetResult();
        }

        [Fact]
        public void VendorSdkRule_SupersededBareTokens_PassTheNexusProviderWrapperFixture()
        {
            var result = RunFixtureRule(BoundaryRuleTests.SupersededBareVendorTokens);

            Assert.True(
                result.IsSuccessful,
                "Control arm: the superseded bare-token list (" +
                string.Join(", ", BoundaryRuleTests.SupersededBareVendorTokens) +
                ") has to be BLIND to the NEXUS provider wrapper, otherwise it is not the defect this " +
                "fixture documents. Failing types: " + Describe(result.FailingTypeNames));
        }

        [Fact]
        public void VendorSdkRule_ShippedNamespaces_FailTheNexusProviderWrapperFixture()
        {
            var result = RunFixtureRule(BoundaryRuleTests.BannedVendorNamespaces);

            Assert.False(
                result.IsSuccessful,
                "The shipped token list (" + string.Join(", ", BoundaryRuleTests.BannedVendorNamespaces) +
                ") must detect a dependency on Nexus.Platform.Providers.OpenAI.*.");

            Assert.Contains(
                "Nexus.Intelligence.Architecture.Tests.Fixtures.FixtureNexusProviderWrapperConsumer",
                result.FailingTypeNames ?? []);
        }

        [Fact]
        public void ProductRule_SupersededNexusProductsToken_PassesTheProductCoreFixture()
        {
            var result = RunFixtureRule(BoundaryRuleTests.SupersededProductTokens);

            Assert.True(
                result.IsSuccessful,
                "Control arm: the superseded 'Nexus.Products' token has to be BLIND to the " +
                "Nexus.ProductCore.* scope trunk, otherwise it is not the defect this fixture " +
                "documents. Failing types: " + Describe(result.FailingTypeNames));
        }

        [Fact]
        public void ProductRule_ShippedNamespaces_FailTheProductCoreFixture()
        {
            var result = RunFixtureRule(BoundaryRuleTests.BannedProductNamespaces);

            Assert.False(
                result.IsSuccessful,
                "The shipped token list (" + string.Join(", ", BoundaryRuleTests.BannedProductNamespaces) +
                ") must detect a dependency on Nexus.ProductCore.*.");

            Assert.Contains(
                "Nexus.Intelligence.Architecture.Tests.Fixtures.FixtureProductCoreConsumer",
                result.FailingTypeNames ?? []);
        }

        private static string Describe(IEnumerable<string>? failingTypeNames) =>
            failingTypeNames is null || !failingTypeNames.Any() ? "(none)" : string.Join(", ", failingTypeNames);
    }
}
