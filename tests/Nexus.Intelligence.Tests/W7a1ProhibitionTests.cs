using System;
using System.Collections.Generic;
using System.Linq;
using Nexus.Intelligence.Contracts;
using Xunit;

namespace Nexus.Intelligence.Tests;

// W7A.1 / item 1: AI_PROHIBITED on the AI dependency classification.
//
// The directive requires the class itself plus deterministic validation for five named surfaces:
// Platform Governance authority, protected Git/merge authority, secret custody, credential material,
// deterministic security gates - and for any capability a Product explicitly prohibits.
//
// Every guard below is paired with an assertion that the guard can FAIL, because a register of
// prohibitions has a failure mode no other contract in this assembly has: a prohibition that was never
// written is indistinguishable, at read time, from a permission. A test suite for prohibitions that
// cannot demonstrate a refusal is a suite that would pass on an empty register.
public sealed class W7a1ProhibitionTests
{
    // ---------------------------------------------------------------------------------------------
    // The class, and the axis it does NOT belong to.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AiProhibited_IsADefinedClass_AndParses()
    {
        Assert.True(Enum.IsDefined(AiDependencyClass.AiProhibited));

        Assert.True(
            AiDependencyClassExtensions.TryParse(nameof(AiDependencyClass.AiProhibited), out var parsed, out var reason),
            $"'{nameof(AiDependencyClass.AiProhibited)}' must be parseable from its own name. Reason: {reason}");

        Assert.Equal(AiDependencyClass.AiProhibited, parsed);

        // Parsing is case-insensitive but not separator-tolerant, which is the behaviour W7A shipped
        // for the other three classes and is asserted here so the new value is held to the same rule
        // rather than quietly acquiring a second accepted spelling.
        Assert.True(AiDependencyClassExtensions.TryParse("aiprohibited", out var lower, out _));
        Assert.Equal(AiDependencyClass.AiProhibited, lower);

        // NEGATIVE: the directive's CAPS_UNDERSCORE token is the class's name in the governance
        // documents, not a parse input. Consistent with AI_OPTIONAL / AI_ENHANCED / AI_DEPENDENT,
        // which were also documented in that form and shipped as PascalCase identifiers, the
        // documented spelling is deliberately NOT a second accepted input. Recorded here so the
        // distinction is visible rather than discovered.
        Assert.False(AiDependencyClassExtensions.TryParse("AI_PROHIBITED", out _, out _));
    }

    // The single sharpest proof that AiProhibited is not a point on the availability scale. If it were
    // "more dependent than dependent", this would have to be false.
    [Fact]
    public void AiProhibited_SurvivesAnAiOutage_BecauseAiWasNeverInIt()
    {
        Assert.True(AiDependencyClass.AiProhibited.MustSurviveAiOutage());

        // Negative control: the availability classes on either side answer differently, so the
        // assertion above is not the vacuous "every class survives".
        Assert.False(AiDependencyClass.AiDependent.MustSurviveAiOutage());
        Assert.True(AiDependencyClass.AiOptional.MustSurviveAiOutage());
        Assert.True(AiDependencyClass.AiEnhanced.MustSurviveAiOutage());
    }

    [Fact]
    public void AiProhibited_IsNotCountedAsAiDependent()
    {
        var registry = new AiDependencyRegistry(
        [
            Decl("governance.gate.evaluate", AiDependencyClass.AiProhibited,
                surface: AiProhibitedSurface.PlatformGovernanceAuthority),
            Decl("chat.reply", AiDependencyClass.AiDependent, riskOwner: "Human Owner"),
        ]);

        Assert.Single(registry.InClass(AiDependencyClass.AiDependent));
        Assert.Single(registry.InClass(AiDependencyClass.AiProhibited));

        // A prohibited path is not a path that fails without AI. It is a path that never had AI.
        Assert.True(registry.MustSurviveAiOutage("governance.gate.evaluate"));
        Assert.False(registry.MustSurviveAiOutage("chat.reply"));
    }

    // ---------------------------------------------------------------------------------------------
    // NEGATIVE: a prohibition with no stated basis is refused.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void Registry_Rejects_AiProhibitedWithoutASurface()
    {
        var error = Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("governance.gate.evaluate", AiDependencyClass.AiProhibited),
        ]));

        Assert.Contains("no prohibited", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Registry_Rejects_AiProhibitedWithAnUndefinedSurface()
    {
        var error = Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("governance.gate.evaluate", AiDependencyClass.AiProhibited,
                surface: (AiProhibitedSurface)99),
        ]));

        Assert.Contains("undefined prohibited surface", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    // ---------------------------------------------------------------------------------------------
    // NEGATIVE: a prohibition cannot be dressed in the vocabulary of the availability classes.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void Registry_Rejects_AiProhibitedThatNamesADeterministicFallback()
    {
        var error = Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("governance.gate.evaluate", AiDependencyClass.AiProhibited,
                surface: AiProhibitedSurface.PlatformGovernanceAuthority,
                fallback: "The deterministic gate decides."),
        ]));

        Assert.Contains("nothing to fall back FROM", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Registry_Rejects_AiProhibitedThatNamesAnAcceptedRiskOwner()
    {
        var error = Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("governance.gate.evaluate", AiDependencyClass.AiProhibited,
                surface: AiProhibitedSurface.PlatformGovernanceAuthority,
                riskOwner: "Human Owner"),
        ]));

        Assert.Contains("accepted-risk", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    // NEGATIVE, the mirror direction: carrying a surface on any other class asserts that AI may
    // participate in a surface the same declaration protects.
    [Theory]
    [InlineData(AiDependencyClass.AiOptional)]
    [InlineData(AiDependencyClass.AiEnhanced)]
    [InlineData(AiDependencyClass.AiDependent)]
    public void Registry_Rejects_ANonProhibitedClassCarryingAProhibitedSurface(AiDependencyClass dependencyClass)
    {
        var error = Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("some.feature", dependencyClass,
                surface: AiProhibitedSurface.SecretCustody,
                fallback: dependencyClass is AiDependencyClass.AiDependent ? null : "Deterministic path.",
                riskOwner: dependencyClass is AiDependencyClass.AiDependent ? "Human Owner" : null),
        ]));

        Assert.Contains("Only an", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    // ---------------------------------------------------------------------------------------------
    // The baseline the directive names, surface by surface.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ProhibitionBaseline_Covers_EverySurfaceTheDirectiveNames()
    {
        // The five the directive names, as a set. Written out here rather than derived from the
        // contract, so that editing the contract cannot silently shrink the baseline: this assertion
        // is the place where the shipped baseline and the instruction are compared.
        AiProhibitedSurface[] requiredByDirective =
        [
            AiProhibitedSurface.PlatformGovernanceAuthority,
            AiProhibitedSurface.ProtectedGitMergeAuthority,
            AiProhibitedSurface.SecretCustody,
            AiProhibitedSurface.CredentialMaterial,
            AiProhibitedSurface.DeterministicSecurityGate,
        ];

        Assert.Equal(
            requiredByDirective.OrderBy(s => s).ToArray(),
            AiProhibitionBaseline.RequiredSurfaces.OrderBy(s => s).ToArray());

        foreach (var surface in requiredByDirective)
        {
            Assert.True(AiProhibitionBaseline.IsRequired(surface), $"{surface} must be part of the baseline.");
        }

        // NEGATIVE: the open Product category is NOT baseline. A Product's own prohibition is its own
        // to declare, so requiring it of every registry would make the baseline unsatisfiable.
        Assert.False(AiProhibitionBaseline.IsRequired(AiProhibitedSurface.ProhibitedProductCapability));
        Assert.Contains(AiProhibitedSurface.ProhibitedProductCapability, AiProhibitionBaseline.AllSurfaces);
        Assert.DoesNotContain(AiProhibitedSurface.ProhibitedProductCapability, AiProhibitionBaseline.RequiredSurfaces);
    }

    [Fact]
    public void Governed_AcceptsARegistryThatCoversTheBaseline_AndRefusesOneThatDoesNot()
    {
        var complete = AiDependencyRegistry.Governed(BaselineDeclarations());
        Assert.True(complete.CoversProhibitionBaseline());
        Assert.Empty(complete.MissingProhibitedSurfaces());

        // NEGATIVE: drop one surface and the same construction must refuse, naming what is missing.
        var incomplete = BaselineDeclarations()
            .Where(d => d.ProhibitedSurface != AiProhibitedSurface.SecretCustody)
            .ToArray();

        var error = Assert.Throws<InvalidOperationException>(() => AiDependencyRegistry.Governed(incomplete));

        Assert.Contains(nameof(AiProhibitedSurface.SecretCustody), error.Message, StringComparison.Ordinal);
        Assert.Contains("permission", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void MissingProhibitedSurfaces_NamesExactlyTheGap()
    {
        var partial = new AiDependencyRegistry(
        [
            Decl("governance.authority.hold", AiDependencyClass.AiProhibited,
                surface: AiProhibitedSurface.PlatformGovernanceAuthority),
        ]);

        var missing = partial.MissingProhibitedSurfaces();

        Assert.Equal(4, missing.Count);
        Assert.DoesNotContain(AiProhibitedSurface.PlatformGovernanceAuthority, missing);
        Assert.Contains(AiProhibitedSurface.ProtectedGitMergeAuthority, missing);
        Assert.Contains(AiProhibitedSurface.SecretCustody, missing);
        Assert.Contains(AiProhibitedSurface.CredentialMaterial, missing);
        Assert.Contains(AiProhibitedSurface.DeterministicSecurityGate, missing);

        // Negative control: the empty register is missing all five, so the assertions above are not
        // passing because the query returns a fixed list.
        Assert.Equal(5, AiDependencyRegistry.Empty.MissingProhibitedSurfaces().Count);
    }

    // ---------------------------------------------------------------------------------------------
    // The decision points.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void MayAiParticipate_IsFalseOnEveryBaselineSurface()
    {
        var registry = AiDependencyRegistry.Governed(BaselineDeclarations());

        foreach (var surface in AiProhibitionBaseline.RequiredSurfaces)
        {
            Assert.True(registry.IsSurfaceProhibited(surface), $"{surface} must read as prohibited.");
            Assert.False(registry.MayAiParticipate(surface), $"{surface} must refuse AI participation.");
        }

        // NEGATIVE: the open Product category is not declared here, so it must NOT read as prohibited.
        // Without this line every assertion above would still pass if the query returned true always.
        Assert.False(registry.IsSurfaceProhibited(AiProhibitedSurface.ProhibitedProductCapability));
        Assert.True(registry.MayAiParticipate(AiProhibitedSurface.ProhibitedProductCapability));
    }

    [Fact]
    public void MayAiServe_IsFalseForAnExplicitlyProhibitedProductCapability()
    {
        var prohibitedCapability = CapabilityId.Parse("product.pricing.recommend");
        var otherCapability = CapabilityId.Parse("product.help.summarise");

        var registry = new AiDependencyRegistry(
        [
            .. BaselineDeclarations(),
            Decl("product.pricing.board", AiDependencyClass.AiProhibited,
                surface: AiProhibitedSurface.ProhibitedProductCapability,
                capability: prohibitedCapability),
        ]);

        Assert.True(registry.IsCapabilityProhibited(prohibitedCapability));
        Assert.False(registry.MayAiServe(prohibitedCapability));
        Assert.Single(registry.ProhibitedFor(prohibitedCapability));

        // NEGATIVE: a neighbouring capability in the same domain is untouched, so the refusal above
        // is the prohibition and not a blanket "no".
        Assert.False(registry.IsCapabilityProhibited(otherCapability));
        Assert.True(registry.MayAiServe(otherCapability));
    }

    // The distinction the register exists to keep clean: "not forbidden" is not "permitted". This is
    // asserted rather than only documented, because it is the property a future caller is most likely
    // to rely on by mistake.
    [Fact]
    public void MayAiServe_TrueMeansNotForbidden_NotPermitted()
    {
        var capability = CapabilityId.Parse("product.help.summarise");
        var registry = new AiDependencyRegistry(BaselineDeclarations());

        Assert.True(registry.MayAiServe(capability));

        // Nothing registered this capability. The true above is an absence of prohibition, and the
        // capability register - the thing that would grant service - does not know the name.
        Assert.Empty(registry.ConsumersOf(capability));
    }

    [Fact]
    public void ProhibitedOn_ReturnsTheDeclarations_AndEmptyForAnUnprohibitedSurface()
    {
        var registry = new AiDependencyRegistry(BaselineDeclarations());

        var custody = registry.ProhibitedOn(AiProhibitedSurface.SecretCustody);
        Assert.Single(custody);
        Assert.Equal("platform.secret.custody", custody[0].FeatureId);
        Assert.Equal("Platform", custody[0].Owner);

        Assert.Empty(registry.ProhibitedOn(AiProhibitedSurface.ProhibitedProductCapability));
    }

    // Disabling a feature does not un-protect the surface it touched. Asserted because the opposite
    // reading - "the flag is off, so the prohibition is off" - is the natural one, and it is wrong:
    // a prohibition is lifted by withdrawing the declaration, which is a governance act, not by
    // flipping an operational toggle.
    [Fact]
    public void Prohibition_IsNotLiftedByDisablingTheFeature()
    {
        var registry = new AiDependencyRegistry(
        [
            Decl("platform.secret.custody", AiDependencyClass.AiProhibited,
                surface: AiProhibitedSurface.SecretCustody, enabled: false),
        ]);

        Assert.False(registry.ProhibitedOn(AiProhibitedSurface.SecretCustody).Single().Enabled);
        Assert.True(registry.IsSurfaceProhibited(AiProhibitedSurface.SecretCustody));
        Assert.False(registry.MayAiParticipate(AiProhibitedSurface.SecretCustody));
    }

    // ---------------------------------------------------------------------------------------------
    // Guards that existed at W7A keep working against the new class.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void Registry_StillRejects_AProhibitedDeclarationMissingOwnerOrRationale()
    {
        var noOwner = Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            new AiDependencyDeclaration
            {
                FeatureId = "platform.secret.custody",
                Owner = "   ",
                DependencyClass = AiDependencyClass.AiProhibited,
                Rationale = "Secret custody is Platform's.",
                ProhibitedSurface = AiProhibitedSurface.SecretCustody,
            },
        ]));
        Assert.Contains("no owner", noOwner.Message, StringComparison.OrdinalIgnoreCase);

        var noRationale = Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            new AiDependencyDeclaration
            {
                FeatureId = "platform.secret.custody",
                Owner = "Platform",
                DependencyClass = AiDependencyClass.AiProhibited,
                Rationale = " ",
                ProhibitedSurface = AiProhibitedSurface.SecretCustody,
            },
        ]));
        Assert.Contains("no rationale", noRationale.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Registry_StillRejects_AFeatureDeclaredTwice_AcrossClasses()
    {
        var error = Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("platform.secret.custody", AiDependencyClass.AiProhibited,
                surface: AiProhibitedSurface.SecretCustody),
            Decl("platform.secret.custody", AiDependencyClass.AiOptional,
                fallback: "The deterministic path is the result."),
        ]));

        Assert.Contains("more than once", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    private static readonly Dictionary<AiProhibitedSurface, (string Feature, string Owner)> BaselineOwners = new()
    {
        [AiProhibitedSurface.PlatformGovernanceAuthority] = ("platform.governance.authority", "Platform"),
        [AiProhibitedSurface.ProtectedGitMergeAuthority] = ("platform.git.merge.authority", "Platform"),
        [AiProhibitedSurface.SecretCustody] = ("platform.secret.custody", "Platform"),
        [AiProhibitedSurface.CredentialMaterial] = ("platform.credential.material", "Platform"),
        [AiProhibitedSurface.DeterministicSecurityGate] = ("platform.security.gate", "Platform"),
    };

    private static IEnumerable<AiDependencyDeclaration> BaselineDeclarations()
        => AiProhibitionBaseline.RequiredSurfaces.Select(surface => Decl(
            BaselineOwners[surface].Feature,
            AiDependencyClass.AiProhibited,
            surface: surface,
            owner: BaselineOwners[surface].Owner));

    private static AiDependencyDeclaration Decl(
        string featureId,
        AiDependencyClass dependencyClass,
        string? fallback = null,
        string? riskOwner = null,
        AiProhibitedSurface? surface = null,
        CapabilityId? capability = null,
        bool enabled = true,
        string owner = "Products / Forge")
        => new()
        {
            FeatureId = featureId,
            Owner = owner,
            DependencyClass = dependencyClass,
            Rationale = "Recorded for the W7A.1 AI_PROHIBITED classification.",
            DeterministicFallback = fallback,
            AcceptedRiskOwner = riskOwner,
            ProhibitedSurface = surface,
            Capability = capability,
            Enabled = enabled,
        };
}
