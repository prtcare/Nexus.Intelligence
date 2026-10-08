using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Governance;
using Xunit;

namespace Nexus.Intelligence.Tests;

// W7B: deterministic AI Governance.
//
// The directive names six properties that must be provable, and every one of them is a property about
// what CANNOT happen:
//
//   1. AI_PROHIBITED always blocks AI participation.
//   2. AI Governance cannot override Platform Governance.
//   3. Prohibited data classifications can be blocked before provider invocation.
//   4. Tool permissions are enforced.
//   5. Budget and policy rejection is deterministic.
//   6. Human-required decisions cannot silently become ALLOW.
//
// A suite for properties of that shape has one failure mode: passing on an engine that refuses
// everything, or on one that permits everything. Every guard below is therefore paired with a control
// that must produce the opposite outcome from the same fixture with one field changed, and the pair is
// usually the same test. Where a control cannot be expressed that way, the assertion says in words what
// it would take to falsify it.
public sealed class W7bGovernanceTests
{
    // =============================================================================================
    // 1. AI_PROHIBITED always blocks AI participation.
    // =============================================================================================

    // Every baseline surface, refused structurally. The fixture's policy carries the EMPTY dependency
    // register, which covers no surface at all - so if the refusal came from a register lookup rather
    // than from AiProhibitionBaseline, all five of these would pass through. That is the assertion.
    [Theory]
    [InlineData(AiProhibitedSurface.PlatformGovernanceAuthority)]
    [InlineData(AiProhibitedSurface.ProtectedGitMergeAuthority)]
    [InlineData(AiProhibitedSurface.SecretCustody)]
    [InlineData(AiProhibitedSurface.CredentialMaterial)]
    [InlineData(AiProhibitedSurface.DeterministicSecurityGate)]
    public void AiProhibitedSurface_Blocks_EvenWithAnEmptyDependencyRegister(AiProhibitedSurface surface)
    {
        var evaluator = Evaluator(Policy());

        var decision = evaluator.Evaluate(
            Request(touchesSurface: surface),
            AiPlatformGovernanceAttestation.NotApplicable);

        Assert.True(decision.IsBlocked, $"{surface} must block. Verdict was {decision.Verdict}.");
        Assert.Equal(AiGovernanceRules.ProhibitedSurface, decision.RuleId);
        Assert.Equal(AiFailureCategory.PolicyBlocked, decision.FailureCategory);

        // The empty register really does cover nothing, so the guard above is not passing because the
        // register refused. This is the control, and it is read off the register rather than assumed.
        Assert.Equal(
            AiProhibitionBaseline.RequiredSurfaces.Count,
            AiDependencyRegistry.Empty.MissingProhibitedSurfaces().Count);
        Assert.True(AiDependencyRegistry.Empty.MayAiParticipate(surface));
    }

    // The open-ended surface is register-driven and NOT baseline, so the same fixture must permit it.
    // Without this, the theory above would still pass on an engine that blocked every surface it was
    // shown.
    [Fact]
    public void ProhibitedProductCapability_IsNotBaseline_SoAnUndeclaredOneIsPermitted()
    {
        var evaluator = Evaluator(Policy());

        var decision = evaluator.Evaluate(
            Request(touchesSurface: AiProhibitedSurface.ProhibitedProductCapability),
            AiPlatformGovernanceAttestation.NotApplicable);

        Assert.True(decision.IsAllowed, $"Verdict was {decision.Verdict}: {decision.Reason}");
    }

    // ...and refused the moment a declaration names it. The pair of these two tests is the proof that
    // the surface check is a real decision and not a constant.
    [Fact]
    public void ProhibitedProductCapability_Blocks_WhenTheRegisterDeclaresIt()
    {
        var evaluator = Evaluator(Policy(dependencies: AiDependencyRegistry.Governed(
        [
            .. BaselineDeclarations(),
            Declaration("product.pricing.board", AiProhibitedSurface.ProhibitedProductCapability),
        ])));

        var decision = evaluator.Evaluate(
            Request(touchesSurface: AiProhibitedSurface.ProhibitedProductCapability),
            AiPlatformGovernanceAttestation.NotApplicable);

        Assert.True(decision.IsBlocked);
        Assert.Equal(AiGovernanceRules.ProhibitedSurface, decision.RuleId);
    }

    [Fact]
    public void ProhibitedCapability_Blocks_EvenWhenEveryOtherStageWouldAllow()
    {
        var capability = CapabilityId.Parse("product.pricing.recommend");
        var evaluator = Evaluator(
            Policy(dependencies: AiDependencyRegistry.Governed(
            [
                .. BaselineDeclarations(),
                Declaration(
                    "product.pricing.board",
                    AiProhibitedSurface.ProhibitedProductCapability,
                    capability: capability),
            ])),
            capabilityRegister: Register(capability));

        var request = Request(capability: capability.Value);

        var decision = evaluator.Evaluate(request, AiPlatformGovernanceAttestation.NotApplicable);

        Assert.True(decision.IsBlocked);
        Assert.Equal(AiGovernanceRules.ProhibitedCapability, decision.RuleId);
        Assert.Equal(AiFailureCategory.PolicyBlocked, decision.FailureCategory);

        // CONTROL: the same request and the same capability registration with the prohibition
        // declaration removed. If the refusal above were the engine refusing everything, this would not
        // be allowed.
        var withoutProhibition = Evaluator(
            Policy(dependencies: AiDependencyRegistry.Governed(BaselineDeclarations())),
            capabilityRegister: Register(capability));

        Assert.True(withoutProhibition.Evaluate(request, AiPlatformGovernanceAttestation.NotApplicable).IsAllowed);
    }

    [Fact]
    public void CapabilityDeclaredAiProhibited_Blocks_AndTheSameRegistrationAtAnotherClassDoesNot()
    {
        var capability = CapabilityId.Parse("product.pricing.recommend");
        var evaluator = Evaluator(
            Policy(),
            capabilityRegister: Register(capability, AiDependencyClass.AiProhibited));

        var decision = evaluator.Evaluate(
            Request(capability: capability.Value),
            AiPlatformGovernanceAttestation.NotApplicable);

        Assert.True(decision.IsBlocked);
        Assert.Equal(AiGovernanceRules.CapabilityDependencyProhibited, decision.RuleId);

        // CONTROL: the identical registration at AiEnhanced is allowed, so the refusal is the class and
        // not the custom register.
        var enhanced = Evaluator(Policy(), capabilityRegister: Register(capability, AiDependencyClass.AiEnhanced));

        Assert.True(enhanced.Evaluate(
            Request(capability: capability.Value),
            AiPlatformGovernanceAttestation.NotApplicable).IsAllowed);
    }

    // =============================================================================================
    // 2. AI Governance cannot override Platform Governance.
    // =============================================================================================

    [Fact]
    public void PlatformRefusal_IsNotOverriddenByAnAiAllow()
    {
        // Every field of this request is in order: a registered, enabled, non-prohibited capability, no
        // surface, no unapproved resource, no tool, no cost. The AI side's own verdict is ALLOW. The
        // platform refused. The result must be the platform's.
        //
        // The authority is Deployment rather than one of the protected-surface authorities, because
        // those are refused for a second, independent reason and this test is about the refusal being
        // carried, not about the surface.
        var evaluator = Evaluator(Policy());

        var decision = evaluator.Evaluate(
            Request(),
            AiPlatformGovernanceAttestation.Refuse(
                AiGovernanceAuthority.Deployment, "The deployment window is closed."));

        Assert.True(decision.IsBlocked, $"Verdict was {decision.Verdict}: {decision.Reason}");
        Assert.Equal(AiGovernanceRules.PlatformAuthorityRefused, decision.RuleId);

        // The platform's reason is carried VERBATIM rather than paraphrased. A governance decision that
        // rewrote the platform's refusal in its own words would put two accounts of one refusal into the
        // record, and the AI-side account is the one that cannot see why the platform decided.
        Assert.Equal("The deployment window is closed.", decision.Reason);
    }

    // The mirror direction: a platform PERMIT does not authorise AI to participate in a surface the
    // platform itself owns. "The platform said yes" is not the AI Head's permission to be in the loop.
    [Fact]
    public void PlatformPermit_DoesNotAuthoriseAiOnAProtectedSurface()
    {
        var evaluator = Evaluator(Policy());

        var decision = evaluator.Evaluate(
            Request(),
            AiPlatformGovernanceAttestation.Permit(AiGovernanceAuthority.PlatformGovernance));

        Assert.True(decision.IsBlocked);
        Assert.Equal(AiGovernanceRules.ProhibitedSurface, decision.RuleId);
        Assert.Equal(
            AiProhibitedSurface.PlatformGovernanceAuthority,
            AiGovernanceAuthority.SurfaceFor(AiGovernanceAuthority.PlatformGovernance));

        // CONTROL: the same permit from an authority that defends no baseline surface is carried as a
        // permit, so the refusal above is the surface and not "the platform was consulted".
        var deployment = evaluator.Evaluate(
            Request(),
            AiPlatformGovernanceAttestation.Permit(AiGovernanceAuthority.Deployment));

        Assert.True(deployment.IsAllowed, deployment.Reason);
    }

    [Fact]
    public void PlatformPermit_IsRecordedAsAttested_OnlyWhenTheAuthorityWasActuallyConsulted()
    {
        var evaluator = Evaluator(Policy());

        var consulted = evaluator.Evaluate(
            Request(),
            AiPlatformGovernanceAttestation.Permit(AiGovernanceAuthority.Deployment));

        Assert.True(consulted.IsAllowed);
        Assert.Contains(AiGovernanceRules.PlatformAuthorityAttested, consulted.RulesApplied);

        // CONTROL: with no platform action attached, the attestation contributes its own identifier and
        // NOT the attested rule, so an audit record cannot report a platform review that never happened.
        var unattached = evaluator.Evaluate(Request(), AiPlatformGovernanceAttestation.NotApplicable);

        Assert.True(unattached.IsAllowed);
        Assert.DoesNotContain(AiGovernanceRules.PlatformAuthorityAttested, unattached.RulesApplied);
        Assert.False(AiPlatformGovernanceAttestation.NotApplicable.AuthorityConsulted);
    }

    // The structural half of the subordination: the interface has exactly one entry point and it cannot
    // be called without an attestation. A second, attestation-free overload would be the code path that
    // reaches an AI verdict without the platform's decision, so its absence is asserted rather than
    // left to review.
    [Fact]
    public void EvaluatorInterface_HasExactlyOneMethod_AndItRequiresThePlatformAttestation()
    {
        var methods = typeof(IAiGovernanceEvaluator).GetMethods();

        Assert.Single(methods);
        Assert.Equal(nameof(IAiGovernanceEvaluator.Evaluate), methods[0].Name);

        var parameters = methods[0].GetParameters();
        Assert.Equal(2, parameters.Length);
        Assert.Equal(typeof(AiGovernanceEvaluationRequest), parameters[0].ParameterType);
        Assert.Equal(typeof(AiPlatformGovernanceAttestation), parameters[1].ParameterType);

        // No optional parameter and no overload: an attestation cannot be defaulted away at the call
        // site, which is how a required-by-contract argument becomes a required-by-convention one.
        Assert.DoesNotContain(parameters, p => p.IsOptional);

        // And the attestation is how the platform's decision travels, so the two are the same fact
        // stated twice: there is no parameter here that could carry "no platform action".
        Assert.True(typeof(AiPlatformGovernanceAttestation).IsSealed);
        Assert.NotNull(AiPlatformGovernanceAttestation.NotApplicable);
    }

    // The composition half: no ordering of Combine can produce a weaker verdict than either input.
    // Asserted over the whole cross product rather than for one pair, because the property being
    // claimed is "for every pair" and a single example would not distinguish it from luck.
    [Fact]
    public void Combine_IsMostRestrictive_ForEveryPairOfVerdicts()
    {
        foreach (var left in Enum.GetValues<AiGovernanceVerdict>())
        {
            foreach (var right in Enum.GetValues<AiGovernanceVerdict>())
            {
                var combined = Decision(left, "governance.escalation.declared")
                    .Combine(Decision(right, "governance.budget.exceeded"));

                var expected = (AiGovernanceVerdict)Math.Max((int)left, (int)right);

                Assert.True(
                    combined.Verdict == expected,
                    $"{left} combined with {right} produced {combined.Verdict}; expected {expected}.");

                // And the same the other way round, so the operator is order-independent.
                var reversed = Decision(right, "governance.budget.exceeded")
                    .Combine(Decision(left, "governance.escalation.declared"));

                Assert.Equal(combined.Verdict, reversed.Verdict);
            }
        }
    }

    // Block outranks HumanDecisionRequired, and the reason is the failure mode the reverse order has:
    // a person invited to grant what a deterministic rule refused.
    [Fact]
    public void Block_Outranks_HumanDecisionRequired()
    {
        Assert.True(AiGovernanceVerdict.Block.MostRestrictive(AiGovernanceVerdict.HumanDecisionRequired)
            is AiGovernanceVerdict.Block);

        Assert.True(AiGovernanceVerdict.HumanDecisionRequired.MostRestrictive(AiGovernanceVerdict.Block)
            is AiGovernanceVerdict.Block);

        // CONTROL: an ALLOW combined with anything is that anything, so the ordering above is not
        // "everything outranks everything".
        foreach (var verdict in Enum.GetValues<AiGovernanceVerdict>())
        {
            Assert.Equal(verdict, AiGovernanceVerdict.Allow.MostRestrictive(verdict));
        }
    }

    // =============================================================================================
    // 3. Prohibited data classifications are blocked BEFORE provider invocation.
    // =============================================================================================

    // The directive's requirement, tested at the seam that makes "before" mean something: the provider
    // is a delegate, and the delegate counts its own calls. Zero calls on a block is the proof; at
    // least one call on the control is what stops the assertion being vacuous.
    [Fact]
    public async Task ProhibitedClassification_Blocks_BeforeTheProviderIsInvoked()
    {
        var evaluator = Evaluator(Policy());
        var calls = 0;

        var blocked = await GovernedProviderInvocation.InvokeAsync(
            evaluator,
            Request(classification: DataClassification.Secret),
            AiPlatformGovernanceAttestation.NotApplicable,
            _ =>
            {
                Interlocked.Increment(ref calls);
                return Task.FromResult("provider payload");
            });

        Assert.True(blocked.Decision.IsBlocked);
        Assert.Equal(AiGovernanceRules.ExposureBlocked, blocked.Decision.RuleId);
        Assert.Equal(AiFailureCategory.DataExposureBlocked, blocked.Decision.FailureCategory);
        Assert.False(blocked.Invoked);
        Assert.Equal(0, calls);
        Assert.Null(blocked.Result);

        // CONTROL: one field changed - the classification - and the provider IS called, exactly once.
        var allowed = await GovernedProviderInvocation.InvokeAsync(
            evaluator,
            Request(classification: DataClassification.Public),
            AiPlatformGovernanceAttestation.NotApplicable,
            _ =>
            {
                Interlocked.Increment(ref calls);
                return Task.FromResult("provider payload");
            });

        Assert.True(allowed.Decision.IsAllowed, allowed.Decision.Reason);
        Assert.True(allowed.Invoked);
        Assert.Equal(1, calls);
        Assert.Equal("provider payload", allowed.Result);
    }

    [Fact]
    public async Task HumanDecisionRequired_DoesNotInvokeTheProvider_Either()
    {
        var evaluator = Evaluator(
            Policy(tools: [Tool("code.analysis.run", ToolSideEffectClass.Write, requiresHumanApproval: true)]));

        var calls = 0;

        var outcome = await GovernedProviderInvocation.InvokeAsync(
            evaluator,
            Request(
                tools: Profile(["code.analysis.run"], ToolSideEffectClass.Write),
                toolIds: ["code.analysis.run"],
                permissionScope: new AiPermissionScope { MayCauseSideEffects = true }),
            AiPlatformGovernanceAttestation.NotApplicable,
            _ =>
            {
                Interlocked.Increment(ref calls);
                return Task.FromResult("provider payload");
            });

        Assert.True(outcome.Decision.RequiresHumanDecision, outcome.Decision.Reason);

        // A decision that had already called the provider would have decided after the thing it was
        // deciding about had happened.
        Assert.False(outcome.Invoked);
        Assert.Equal(0, calls);
    }

    // Customer data is local-only in the default table. The block is a property of the destination,
    // which is why a local destination for the same content is permitted - an engine that refused
    // customer data outright would be refusing the common case.
    [Fact]
    public void CustomerData_MayNotReachARemoteProvider_ButMayBeProcessedLocally()
    {
        var evaluator = Evaluator(Policy(register: Governed()
            .WithModel(Model("model-w7b", "provider-w7b"))
            .WithProvider(Provider("provider-w7b", permitsEgress: true, trust: AiProviderTrustTier.Sovereign))));

        var remote = evaluator.Evaluate(
            Request(
                classification: DataClassification.CustomerData,
                destination: AiDestinationClass.RemoteProvider,
                modelId: "model-w7b",
                providerId: "provider-w7b"),
            Attestation());

        Assert.True(remote.IsBlocked);
        Assert.Equal(AiGovernanceRules.ExposureBlocked, remote.RuleId);

        var local = evaluator.Evaluate(
            Request(
                classification: DataClassification.CustomerData,
                destination: AiDestinationClass.Local,
                modelId: "model-w7b",
                providerId: "provider-w7b"),
            Attestation());

        Assert.True(local.IsAllowed, local.Reason);
    }

    // =============================================================================================
    // 4. Tool permissions are enforced.
    // =============================================================================================

    [Fact]
    public void ToolNotInThePermissionProfile_IsRefused()
    {
        var evaluator = Evaluator(Policy(tools: [Tool("code.analysis.run", ToolSideEffectClass.Read)]));

        var decision = evaluator.Evaluate(
            Request(tools: ToolPermissionProfile.ReadOnly(), toolIds: ["code.analysis.run"]),
            Attestation());

        // The tool is not in AllowedToolIds, which ReadOnly() leaves empty.
        Assert.True(decision.IsBlocked);
        Assert.Equal(AiGovernanceRules.ToolNotPermitted, decision.RuleId);

        // CONTROL: name it in the profile and the same request is allowed, so the refusal is the
        // profile and not the tool register.
        var allowed = evaluator.Evaluate(
            Request(tools: ReadOnlyWith(16, "code.analysis.run"), toolIds: ["code.analysis.run"]),
            Attestation());

        Assert.True(allowed.IsAllowed, allowed.Reason);
    }

    [Fact]
    public void ToolUnknownToTheGovernanceRegister_IsRefused()
    {
        var evaluator = Evaluator(Policy());

        // Permitted by the profile, absent from the tool register. Absence of a classification is
        // treated as the worst case, not the mildest - otherwise a newly registered tool would be
        // permitted by omission.
        var unknown = evaluator.Evaluate(
            Request(tools: ReadOnlyWith(16, "code.analysis.run"), toolIds: ["code.analysis.run"]),
            Attestation());

        Assert.True(unknown.IsBlocked);
        Assert.Equal(AiGovernanceRules.ToolUnknown, unknown.RuleId);
        Assert.Equal(AiFailureCategory.ToolPermissionDenied, unknown.FailureCategory);
    }

    [Fact]
    public void ToolSideEffectAboveTheProfileCeiling_IsRefused_EvenWhenTheToolIsNamed()
    {
        var evaluator = Evaluator(Policy(
            tools: [Tool("code.analysis.run", ToolSideEffectClass.External, requiresHumanApproval: true)]));

        var decision = evaluator.Evaluate(
            Request(
                // Named in AllowedToolIds, which is exactly the case the ceiling exists for: a list
                // permits by omission, a ceiling cannot.
                tools: Profile(["code.analysis.run"], ToolSideEffectClass.Read),
                toolIds: ["code.analysis.run"]),
            Attestation());

        Assert.True(decision.IsBlocked);
        Assert.Equal(AiGovernanceRules.ToolSideEffectExceeded, decision.RuleId);
    }

    [Fact]
    public void WriteTool_IsRefused_WhenTheRequesterMayNotCauseSideEffects()
    {
        var evaluator = Evaluator(Policy(tools: [Tool("code.analysis.run", ToolSideEffectClass.Write)]));

        var decision = evaluator.Evaluate(
            Request(
                tools: Profile(["code.analysis.run"], ToolSideEffectClass.Write, requireApprovalForWrites: false),
                toolIds: ["code.analysis.run"],
                // MayCauseSideEffects defaults to false; stated here to be explicit, and
                // RequiresHumanApprovalForSideEffects is turned off so that the only remaining reason
                // for a refusal is the permission to cause at all.
                permissionScope: new AiPermissionScope
                {
                    MayCauseSideEffects = false,
                    RequiresHumanApprovalForSideEffects = false,
                }),
            Attestation());

        Assert.True(decision.IsBlocked);
        Assert.Equal(AiGovernanceRules.ToolNotPermitted, decision.RuleId);
    }

    [Theory]
    [InlineData(true, false, false)]  // the profile demands approval
    [InlineData(false, true, false)]  // the tool register demands it
    [InlineData(false, false, true)]  // the requester's own scope demands it
    public void WriteTool_RequiresAHumanDecision_WhenAnyOfTheThreeApprovalRulesApplies(
        bool profileRequiresApproval,
        bool toolRequiresApproval,
        bool scopeRequiresApproval)
    {
        var evaluator = Evaluator(Policy(
            tools: [Tool("code.analysis.run", ToolSideEffectClass.Write, toolRequiresApproval)]));

        var decision = evaluator.Evaluate(
            Request(
                tools: Profile(["code.analysis.run"], ToolSideEffectClass.Write, profileRequiresApproval),
                toolIds: ["code.analysis.run"],
                permissionScope: new AiPermissionScope
                {
                    MayCauseSideEffects = true,
                    RequiresHumanApprovalForSideEffects = scopeRequiresApproval,
                }),
            Attestation());

        Assert.True(decision.RequiresHumanDecision, decision.Reason);
        Assert.Equal(AiGovernanceRules.ToolApprovalRequired, decision.RuleId);
        Assert.Equal(AiFailureCategory.HumanDecisionRequired, decision.FailureCategory);
    }

    // The control for the theory above: all three approval rules off, and the same write is permitted.
    // Without this, "a write tool needs a human" would be indistinguishable from "a write tool is always
    // escalated", which would make the escalation meaningless.
    [Fact]
    public void WriteTool_IsPermitted_WhenNoApprovalRuleApplies()
    {
        var evaluator = Evaluator(Policy(
            tools: [Tool("code.analysis.run", ToolSideEffectClass.Write)]));

        var decision = evaluator.Evaluate(
            Request(
                tools: Profile(["code.analysis.run"], ToolSideEffectClass.Write, requireApprovalForWrites: false),
                toolIds: ["code.analysis.run"],
                permissionScope: new AiPermissionScope
                {
                    MayCauseSideEffects = true,
                    RequiresHumanApprovalForSideEffects = false,
                }),
            Attestation());

        Assert.True(decision.IsAllowed, decision.Reason);
    }

    [Fact]
    public void ToolCallCeiling_IsEnforced_AndTheSameCallsWithinItAreAllowed()
    {
        var evaluator = Evaluator(Policy(tools:
        [
            Tool("code.analysis.read", ToolSideEffectClass.Read),
            Tool("code.analysis.list", ToolSideEffectClass.Read),
        ]));

        string[] tools = ["code.analysis.read", "code.analysis.list"];

        var decision = evaluator.Evaluate(
            Request(tools: ReadOnlyWith(1, tools), toolIds: tools),
            Attestation());

        Assert.True(decision.IsBlocked);
        Assert.Equal(AiGovernanceRules.ToolCallCeilingExceeded, decision.RuleId);

        // CONTROL: the same two tools within a ceiling of two are allowed.
        var allowed = evaluator.Evaluate(
            Request(tools: ReadOnlyWith(2, tools), toolIds: tools),
            Attestation());

        Assert.True(allowed.IsAllowed, allowed.Reason);
    }

    // A negative ceiling is a malformed profile, and it is refused rather than read as "unlimited". The
    // interesting case is the one with NO tools requested: a guard written as `count > ceiling` alone
    // would let it through, so a typo of -1 would silently disable the runaway-loop bound for exactly the
    // executions nobody looked at.
    [Fact]
    public void NegativeToolCallCeiling_IsRefused_RatherThanReadAsUnlimited()
    {
        var evaluator = Evaluator(Policy(tools: [Tool("code.analysis.read", ToolSideEffectClass.Read)]));

        var noTools = evaluator.Evaluate(
            Request(tools: ReadOnlyWith(-1)),
            Attestation());

        Assert.True(noTools.IsBlocked, noTools.Reason);
        Assert.Equal(AiGovernanceRules.ToolCallCeilingExceeded, noTools.RuleId);
        Assert.Equal(AiFailureCategory.ToolPermissionDenied, noTools.FailureCategory);

        // CONTROL: the same profile with a real ceiling and the same (empty) call list is allowed, so the
        // refusal is the malformed ceiling and not the empty list.
        Assert.True(Evaluator(Policy()).Evaluate(
            Request(tools: ReadOnlyWith(16)),
            Attestation()).IsAllowed);
    }

    // =============================================================================================
    // 5. Budget and policy rejection is deterministic.
    // =============================================================================================

    [Fact]
    public void CostAboveTheBudgetCeiling_IsRefused_AndBelowItIsAllowed()
    {
        var evaluator = Evaluator(Policy(budgets: [Budget("budget.code.review", 0.50m)]));

        var over = evaluator.Evaluate(
            Request(estimatedCost: 0.75m, execution: Priced(0.75m)),
            Attestation());

        Assert.True(over.IsBlocked);
        Assert.Equal(AiGovernanceRules.BudgetExceeded, over.RuleId);
        Assert.Equal(AiFailureCategory.BudgetBlocked, over.FailureCategory);

        var under = evaluator.Evaluate(
            Request(estimatedCost: 0.25m, execution: Priced(0.25m)),
            Attestation());

        Assert.True(under.IsAllowed, under.Reason);
    }

    [Fact]
    public void BudgetRuleThatEscalates_ProducesAHumanDecision_NotABlock()
    {
        var evaluator = Evaluator(Policy(budgets:
        [
            Budget("budget.code.review", 0.50m, AiGovernanceVerdict.HumanDecisionRequired),
        ]));

        var decision = evaluator.Evaluate(
            Request(estimatedCost: 0.75m, execution: Priced(0.75m)),
            Attestation());

        Assert.True(decision.RequiresHumanDecision, decision.Reason);
        Assert.Equal(AiGovernanceRules.BudgetExceeded, decision.RuleId);
        Assert.False(decision.IsAllowed);
    }

    [Fact]
    public void PricedExecutionWithNoBudgetRule_IsRefused_UnlessThePolicySaysAnUncoveredCostIsAcceptable()
    {
        var strict = Evaluator(Policy());

        var uncovered = strict.Evaluate(
            Request(estimatedCost: 0.75m, execution: Priced(0.75m)),
            Attestation());

        Assert.True(uncovered.IsBlocked);
        Assert.Equal(AiGovernanceRules.BudgetUncovered, uncovered.RuleId);

        // CONTROL: the same priced execution under a policy that says an uncovered cost is acceptable.
        // Both behaviours are policy records, so the difference is the record and not the engine.
        var permissive = Evaluator(Policy(requireBudgetRuleForPricedExecution: false));

        Assert.True(permissive.Evaluate(
            Request(estimatedCost: 0.75m, execution: Priced(0.75m)),
            Attestation()).IsAllowed);
    }

    [Fact]
    public void CurrencyThatCannotBeComparedToTheCeiling_IsRefused()
    {
        var evaluator = Evaluator(Policy(budgets: [Budget("budget.code.review", 10m)]));

        var mismatched = evaluator.Evaluate(
            Request(estimatedCost: 5m, execution: Priced(5m, "EUR")),
            Attestation());

        Assert.True(mismatched.IsBlocked);
        Assert.Equal(AiGovernanceRules.BudgetUncovered, mismatched.RuleId);

        // An absent currency is not a wildcard. It is a number whose unit nobody stated, and comparing
        // it to a ceiling anyway is the defect the currency field exists to prevent.
        var unstated = evaluator.Evaluate(
            Request(estimatedCost: 5m, execution: Priced(5m, currency: null)),
            Attestation());

        Assert.True(unstated.IsBlocked);
        Assert.Equal(AiGovernanceRules.BudgetUncovered, unstated.RuleId);

        // CONTROL: the matching currency is allowed, so neither refusal above is a blanket one.
        var matched = evaluator.Evaluate(
            Request(estimatedCost: 5m, execution: Priced(5m)),
            Attestation());

        Assert.True(matched.IsAllowed, matched.Reason);
    }

    // Determinism, asserted as an equality over the whole decision rather than over the verdict alone:
    // two identical requests must produce identical verdicts, deciding rules, applied rule sets and
    // reasons. A verdict that agreed while the reason differed would not be auditable.
    [Fact]
    public void TheSameRequest_ProducesAnIdenticalDecision_EveryTime()
    {
        AiGovernancePolicy Build() => Policy(budgets:
        [
            Budget("budget.code.review", 0.50m, AiGovernanceVerdict.HumanDecisionRequired),
        ]);

        var request = Request(estimatedCost: 0.75m, execution: Priced(0.75m));

        var first = Evaluator(Build()).Evaluate(request, Attestation());
        var second = Evaluator(Build()).Evaluate(request, Attestation());
        var third = Evaluator(Build()).Evaluate(request, Attestation());

        Assert.True(first.RequiresHumanDecision, first.Reason);

        Assert.Equal(first.Verdict, second.Verdict);
        Assert.Equal(first.RuleId, second.RuleId);
        Assert.Equal(first.Reason, second.Reason);
        Assert.Equal(first.RulesApplied, second.RulesApplied);
        Assert.Equal(first.FailureCategory, second.FailureCategory);

        // A third evaluator argues immediately, so the determinism is a property of the policy rather
        // than of one instance's accumulated state.
        Assert.Equal(first.Verdict, third.Verdict);
        Assert.Equal(first.RuleId, third.RuleId);
        Assert.Equal(first.RulesApplied, third.RulesApplied);
    }

    // =============================================================================================
    // 6. A human-required decision cannot silently become ALLOW.
    // =============================================================================================

    [Fact]
    public void HumanDecisionRequired_SurvivesCombinationWithAnAllow_InBothOrders()
    {
        var human = AiGovernanceDecision.HumanDecisionRequired(
            AiGovernanceRules.ToolApprovalRequired, "A person must approve the write.");

        var allow = AiGovernanceDecision.Allow();

        Assert.True(human.Combine(allow).RequiresHumanDecision);
        Assert.True(allow.Combine(human).RequiresHumanDecision);
        Assert.False(human.Combine(allow).IsAllowed);
        Assert.False(allow.Combine(human).IsAllowed);
    }

    [Fact]
    public void AnEscalation_ProducesAFailureThatIsNotRetryableAndRequiresAHuman()
    {
        var decision = AiGovernanceDecision.HumanDecisionRequired(
            AiGovernanceRules.BudgetExceeded, "Over budget; the owner decides.");

        var failure = decision.ToFailure("corr-w7b");

        Assert.NotNull(failure);
        Assert.Equal(AiFailureCategory.HumanDecisionRequired, failure!.Category);
        Assert.True(failure.RequiresHumanAction);
        Assert.False(failure.Retryable);

        // CONTROL: an allowed decision produces no failure at all, so the assertions above are about a
        // failure that exists rather than about a default.
        Assert.Null(AiGovernanceDecision.Allow().ToFailure("corr-w7b"));
    }

    [Fact]
    public void EscalationRule_MakesTheDecisionHuman_AndTheControlWithoutItIsAllowed()
    {
        var evaluator = Evaluator(Policy(escalations:
        [
            new AiGovernanceEscalationRule
            {
                RuleId = "escalate.code.review.production",
                Subject = AiGovernanceSubject.Evaluation,
                Capability = CapabilityId.Parse("code.review"),
                Reason = "Reviews of production changes are read by a human before they are acted on.",
            },
        ]));

        var escalated = evaluator.Evaluate(Request(), Attestation());

        Assert.True(escalated.RequiresHumanDecision, escalated.Reason);
        Assert.Equal(AiGovernanceRules.EscalationDeclared, escalated.RuleId);
        Assert.Contains("escalate.code.review.production", escalated.RulesApplied);

        // CONTROL: the same policy without the record.
        var plain = Evaluator(Policy()).Evaluate(Request(), Attestation());

        Assert.True(plain.IsAllowed, plain.Reason);
    }

    // A block is terminal, so a request that is already refused is not additionally escalated: asking a
    // person about a refusal suggests the refusal is theirs to lift.
    [Fact]
    public void ABlockedRequest_IsNotAlsoEscalated_ButAnAllowedOneIs()
    {
        var evaluator = Evaluator(Policy(escalations:
        [
            new AiGovernanceEscalationRule
            {
                RuleId = "escalate.prohibited.surface",
                Subject = AiGovernanceSubject.ProhibitedSurface,
                Reason = "Every execution on a protected surface is read by a human.",
            },
        ]));

        var blocked = evaluator.Evaluate(
            Request(touchesSurface: AiProhibitedSurface.SecretCustody),
            Attestation());

        Assert.True(blocked.IsBlocked);
        Assert.Equal(AiGovernanceRules.ProhibitedSurface, blocked.RuleId);
        Assert.DoesNotContain(AiGovernanceRules.EscalationDeclared, blocked.RulesApplied);

        // CONTROL: the same escalation rule on a request that is not blocked does fire, so the absence
        // above is the block and not a rule that never matches.
        var allowed = evaluator.Evaluate(Request(), Attestation());

        Assert.True(allowed.RequiresHumanDecision, allowed.Reason);
        Assert.Contains(AiGovernanceRules.EscalationDeclared, allowed.RulesApplied);
    }

    // =============================================================================================
    // The rule vocabulary and the policy records.
    // =============================================================================================

    [Fact]
    public void EveryRuleIdentifier_IsWellFormed_Distinct_AndResolvable()
    {
        Assert.NotEmpty(AiGovernanceRules.All);
        Assert.Equal(AiGovernanceRules.All.Count, AiGovernanceRules.All.Distinct(StringComparer.Ordinal).Count());

        foreach (var ruleId in AiGovernanceRules.All)
        {
            Assert.True(CapabilityId.IsValid(ruleId), $"Rule identifier '{ruleId}' is not well formed.");
            Assert.True(AiGovernanceRules.IsKnown(ruleId), $"Rule identifier '{ruleId}' is not resolvable.");
        }

        // NEGATIVE: an unknown identifier is not known, and a malformed one is not either - the guard
        // is a membership test over a validated vocabulary, not "any non-empty string".
        Assert.False(AiGovernanceRules.IsKnown("governance.not.a.rule"));
        Assert.False(AiGovernanceRules.IsKnown("Governance.Allowed"));
        Assert.False(AiGovernanceRules.IsKnown("governance"));
        Assert.False(AiGovernanceRules.IsKnown("governance.allowed.v1"));
        Assert.False(AiGovernanceRules.IsKnown(null));
    }

    [Fact]
    public void VerdictTokens_AreExactlyTheThreeTheDirectiveNames()
    {
        Assert.Equal("ALLOW", AiGovernanceVerdict.Allow.ToToken());
        Assert.Equal("HUMAN_DECISION_REQUIRED", AiGovernanceVerdict.HumanDecisionRequired.ToToken());
        Assert.Equal("BLOCK", AiGovernanceVerdict.Block.ToToken());

        Assert.False(AiGovernanceVerdict.Allow.IsRefusal());
        Assert.True(AiGovernanceVerdict.HumanDecisionRequired.IsRefusal());
        Assert.True(AiGovernanceVerdict.Block.IsRefusal());
        Assert.True(AiGovernanceVerdict.Block.IsHardBlock());
        Assert.False(AiGovernanceVerdict.HumanDecisionRequired.IsHardBlock());
    }

    [Theory]
    [InlineData("budget.rules.over", -1d, "USD", AiGovernanceVerdict.Block, "ceiling")]
    [InlineData("budget.rules.blank-currency", 1d, " ", AiGovernanceVerdict.Block, "currency")]
    [InlineData("budget.rules.permissive", 1d, "USD", AiGovernanceVerdict.Allow, "comment")]
    [InlineData("governance.allowed", 1d, "USD", AiGovernanceVerdict.Block, "impersonate")]
    [InlineData("Not.An.Identifier", 1d, "USD", AiGovernanceVerdict.Block, "invalid identifier")]
    public void PolicyValidation_RefusesAMalformedBudgetRule(
        string ruleId,
        double ceiling,
        string currency,
        AiGovernanceVerdict onExceeded,
        string expectedFragment)
    {
        var policy = Policy(budgets:
        [
            new AiGovernanceBudgetRule
            {
                RuleId = ruleId,
                Ceiling = (decimal)ceiling,
                Currency = currency,
                OnExceeded = onExceeded,
                Rationale = "Recorded for the validation fixture.",
            },
        ]);

        var error = Assert.Throws<ArgumentException>(policy.Validate);

        Assert.Contains(expectedFragment, error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void PolicyValidation_RefusesAToolRuleWithNoToolAndAnEscalationWithNoReason()
    {
        var noTool = Assert.Throws<ArgumentException>(Policy(tools:
        [
            new AiGovernanceToolRule
            {
                RuleId = "tool.code.analysis.run",
                ToolId = "  ",
                SideEffect = ToolSideEffectClass.Read,
                Rationale = "Recorded for the validation fixture.",
            },
        ]).Validate);

        Assert.Contains("no tool", noTool.Message, StringComparison.OrdinalIgnoreCase);

        var noReason = Assert.Throws<ArgumentException>(Policy(escalations:
        [
            new AiGovernanceEscalationRule
            {
                RuleId = "escalate.code.review",
                Subject = AiGovernanceSubject.Evaluation,
                Reason = " ",
            },
        ]).Validate);

        Assert.Contains("no reason", noReason.Message, StringComparison.OrdinalIgnoreCase);
    }

    // The evaluator validates at construction, not on the first request that reaches the broken record.
    [Fact]
    public void Evaluator_RefusesAMalformedPolicyAtConstruction_NotOnTheFirstRequest()
    {
        var error = Assert.Throws<ArgumentException>(() => Evaluator(Policy(budgets:
        [
            Budget("budget.rules.permissive", 1m, AiGovernanceVerdict.Allow),
        ])));

        Assert.Contains("comment", error.Message, StringComparison.OrdinalIgnoreCase);

        // CONTROL: the same policy with the verdict corrected constructs, so the throw above is the
        // record and not the fixture.
        Assert.NotNull(Evaluator(Policy(budgets: [Budget("budget.rules.corrected", 1m)])));
    }

    // The default policy is closed, and it says so by refusing every execution that names a governed
    // resource. This is the state of an estate whose registry lane has not run.
    [Fact]
    public void DefaultPolicy_RefusesEveryUnregisteredResource_AndPermitsNoResourceRequest()
    {
        var evaluator = Evaluator(AiGovernancePolicy.Default());

        var named = evaluator.Evaluate(
            Request(modelId: "unregistered-model", providerId: "unregistered-provider"),
            Attestation());

        Assert.True(named.IsBlocked);
        Assert.Equal(AiGovernanceRules.ModelUnregistered, named.RuleId);

        // CONTROL: the same policy permits a request that names no resource at all, so "closed" means
        // "nothing unapproved proceeds" rather than "nothing proceeds".
        var unnamed = evaluator.Evaluate(Request(), Attestation());

        Assert.True(unnamed.IsAllowed, unnamed.Reason);
    }

    [Fact]
    public void UnregisteredAgentAndPrompt_AreRefused_AndApprovedOnesAreNot()
    {
        var capability = CapabilityId.Parse("code.review");
        var bare = Evaluator(Policy());

        Assert.Equal(
            AiGovernanceRules.AgentUnregistered,
            bare.Evaluate(Request(agentId: "agent-w7b"), Attestation()).RuleId);

        Assert.Equal(
            AiGovernanceRules.PromptUnregistered,
            bare.Evaluate(Request(promptId: "prompt-w7b", promptVersion: "1.0.0"), Attestation()).RuleId);

        var governed = Evaluator(Policy(register: Governed()
            .WithAgent(new AiAgentGovernanceRecord
            {
                AgentId = "agent-w7b",
                Status = AiGovernanceApprovalStatus.Approved,
                AllowedCapabilities = [capability],
                MaxSideEffect = ToolSideEffectClass.Read,
                Rationale = "Approved for review-shaped work.",
            })
            .WithPrompt(new AiPromptGovernanceRecord
            {
                PromptId = "prompt-w7b",
                ApprovedVersion = "1.0.0",
                Status = AiGovernanceApprovalStatus.Approved,
                Owner = "AI-03 AI Governance",
                Rationale = "The reviewed instruction set for review-shaped work.",
            })));

        Assert.True(governed.Evaluate(
            Request(agentId: "agent-w7b", promptId: "prompt-w7b", promptVersion: "1.0.0"),
            Attestation()).IsAllowed);

        // NEGATIVE: an unreviewed version of an approved prompt is an unapproved prompt.
        var otherVersion = governed.Evaluate(
            Request(promptId: "prompt-w7b", promptVersion: "1.0.1"),
            Attestation());

        Assert.True(otherVersion.IsBlocked);
        Assert.Equal(AiGovernanceRules.PromptNotApproved, otherVersion.RuleId);

        // NEGATIVE: an agent is not approved for a capability it does not list.
        var otherCapability = governed.Evaluate(
            Request(capability: "code.generate", agentId: "agent-w7b"),
            Attestation());

        Assert.True(otherCapability.IsBlocked);
        Assert.Equal(AiGovernanceRules.AgentCapabilityNotPermitted, otherCapability.RuleId);

        // NEGATIVE: a prompt named with no version at all cannot be reproduced from its own record.
        var unversioned = governed.Evaluate(
            Request(promptId: "prompt-w7b", promptVersion: "  "),
            Attestation());

        Assert.True(unversioned.IsBlocked);
        Assert.Equal(AiGovernanceRules.PromptUnversioned, unversioned.RuleId);
    }

    [Fact]
    public void SuspendedModel_IsRefused_AndTheSameRecordApprovedIsNot()
    {
        var model = new AiModelGovernanceRecord
        {
            ModelId = "model-w7b",
            ProviderId = "provider-w7b",
            Status = AiGovernanceApprovalStatus.Suspended,
            MaxClassification = DataClassification.Secret,
            Rationale = "Suspended pending a re-assessment.",
        };

        var suspended = Evaluator(Policy(register: Governed().WithModel(model)));

        Assert.Equal(
            AiGovernanceRules.ModelNotApproved,
            suspended.Evaluate(Request(modelId: "model-w7b"), Attestation()).RuleId);

        var approved = Evaluator(Policy(register: Governed().WithModel(model with
        {
            Status = AiGovernanceApprovalStatus.Approved,
        })));

        Assert.True(approved.Evaluate(Request(modelId: "model-w7b"), Attestation()).IsAllowed);
    }

    [Fact]
    public void ModelClassificationCeiling_IsEnforced_IndependentlyOfTheExposureTable()
    {
        var model = new AiModelGovernanceRecord
        {
            ModelId = "model-w7b",
            ProviderId = "provider-w7b",
            Status = AiGovernanceApprovalStatus.Approved,
            MaxClassification = DataClassification.Internal,
            Rationale = "Cleared for internal material only.",
        };

        var evaluator = Evaluator(Policy(register: Governed().WithModel(model)));

        // Pii may reach a local destination under the default exposure table, so the exposure stage
        // permits this. The model's own ceiling is what refuses it - the narrower clearance wins.
        var decision = evaluator.Evaluate(
            Request(classification: DataClassification.Pii, modelId: "model-w7b"),
            Attestation());

        Assert.True(decision.IsBlocked, decision.Reason);
        Assert.Equal(AiGovernanceRules.ModelClassificationCeiling, decision.RuleId);

        // CONTROL: the same request at the model's own ceiling is allowed.
        Assert.True(evaluator.Evaluate(
            Request(classification: DataClassification.Internal, modelId: "model-w7b"),
            Attestation()).IsAllowed);
    }

    // The provider has its own classification ceiling, granted independently of the model's, and it
    // reports its own rule. A shared identifier would leave the audit record unable to say which of the
    // two clearances the execution hit - the provider was assessed separately, so the refusal was too.
    [Fact]
    public void ProviderClassificationCeiling_IsEnforced_AndReportsItsOwnRule()
    {
        var evaluator = Evaluator(Policy(register: Governed()
            .WithModel(Model("model-w7b", "provider-w7b"))
            .WithProvider(Provider(
                "provider-w7b",
                permitsEgress: true,
                trust: AiProviderTrustTier.Sovereign,
                maxClassification: DataClassification.Internal))));

        var remote = Request(
            classification: DataClassification.Pii,
            destination: AiDestinationClass.RemoteProvider,
            modelId: "model-w7b",
            providerId: "provider-w7b");

        var decision = evaluator.Evaluate(remote, Attestation());

        Assert.True(decision.IsBlocked, decision.Reason);
        Assert.Equal(AiGovernanceRules.ProviderClassificationCeiling, decision.RuleId);
        Assert.Equal(AiFailureCategory.DataExposureBlocked, decision.FailureCategory);

        // The model is cleared for the same content, so this really is the provider's ceiling firing
        // rather than the model's - which is the distinction the separate rule identifier exists for.
        Assert.Equal(DataClassification.Secret, Model("model-w7b", "provider-w7b").MaxClassification);
        Assert.NotEqual(AiGovernanceRules.ModelClassificationCeiling, decision.RuleId);

        // CONTROL: the same request at the provider's own ceiling is allowed.
        Assert.True(evaluator.Evaluate(
            remote with { Classification = DataClassification.Internal },
            Attestation()).IsAllowed);
    }

    [Fact]
    public void RemoteExecution_RequiresANamedModel()
    {
        var evaluator = Evaluator(Policy());

        var unnamed = evaluator.Evaluate(
            Request(destination: AiDestinationClass.RemoteProvider),
            Attestation());

        Assert.True(unnamed.IsBlocked);
        Assert.Equal(AiGovernanceRules.ModelUnregistered, unnamed.RuleId);

        // CONTROL: the same unnamed execution at a local destination is allowed, so the requirement is
        // about what governance cannot see rather than about naming a model for its own sake.
        Assert.True(evaluator.Evaluate(
            Request(destination: AiDestinationClass.Local),
            Attestation()).IsAllowed);
    }

    [Fact]
    public void ProviderEgressAndTrustFloor_AreBothEnforced()
    {
        var model = Model("model-w7b", "provider-w7b");

        AiGovernanceEvaluationRequest Remote() => Request(
            classification: DataClassification.Public,
            destination: AiDestinationClass.RemoteProvider,
            modelId: "model-w7b",
            providerId: "provider-w7b");

        var noEgress = Evaluator(Policy(register: Governed().WithModel(model).WithProvider(
            Provider("provider-w7b", permitsEgress: false, trust: AiProviderTrustTier.Sovereign))));

        var blocked = noEgress.Evaluate(Remote(), Attestation());

        Assert.True(blocked.IsBlocked);
        Assert.Equal(AiGovernanceRules.SecurityEgressNotPermitted, blocked.RuleId);

        // Below the floor: egress is permitted, but the provider has not been assessed far enough.
        var lowTrust = Evaluator(Policy(
            register: Governed().WithModel(model).WithProvider(
                Provider("provider-w7b", permitsEgress: true, trust: AiProviderTrustTier.Untrusted))));

        var untrusted = lowTrust.Evaluate(Remote(), Attestation());

        Assert.True(untrusted.IsBlocked);
        Assert.Equal(AiGovernanceRules.SecurityTrustBelowFloor, untrusted.RuleId);

        // CONTROL: egress permitted and trust at the floor is allowed.
        var sovereign = Evaluator(Policy(register: Governed().WithModel(model).WithProvider(
            Provider("provider-w7b", permitsEgress: true, trust: AiProviderTrustTier.Sovereign))));

        Assert.True(sovereign.Evaluate(Remote(), Attestation()).IsAllowed);
    }

    [Fact]
    public void ContextAbovePublicWithNoDeclaredDataScope_IsRefused()
    {
        var evaluator = Evaluator(Policy());

        var undeclared = evaluator.Evaluate(
            Request(context: [DataClassification.Internal]),
            Attestation());

        Assert.True(undeclared.IsBlocked);
        Assert.Equal(AiGovernanceRules.ContextScopeUndeclared, undeclared.RuleId);

        // CONTROL: the same context with a declared scope is allowed, and Public context needs none.
        Assert.True(evaluator.Evaluate(
            Request(context: [DataClassification.Internal], dataScopes: ["tenant:acme"]),
            Attestation()).IsAllowed);

        Assert.True(evaluator.Evaluate(
            Request(context: [DataClassification.Public]),
            Attestation()).IsAllowed);
    }

    [Fact]
    public void StrictQualityWithASilentDeterministicFallback_IsRefused_AsSelfContradictory()
    {
        var evaluator = Evaluator(Policy());

        var contradictory = evaluator.Evaluate(
            Request(execution: new AiExecutionPolicy
            {
                Quality = AiQualityRequirement.Structured,
                OnDegradation = AiDegradationPreference.ReturnDeterministicResult,
            }),
            Attestation());

        Assert.True(contradictory.IsBlocked);
        Assert.Equal(AiGovernanceRules.EvaluationQualityUnevidenced, contradictory.RuleId);

        // The same strict requirement with a degradation preference that can honour it is allowed, so
        // the refusal is the contradiction and not the strictness.
        Assert.True(evaluator.Evaluate(
            Request(execution: new AiExecutionPolicy
            {
                Quality = AiQualityRequirement.Structured,
                OnDegradation = AiDegradationPreference.Fail,
            }),
            Attestation()).IsAllowed);

        // A strict citation requirement with nothing to cite is a decision for a person: either the
        // requirement is wrong for this request or the source was not attached.
        var uncitable = evaluator.Evaluate(
            Request(execution: new AiExecutionPolicy
            {
                Quality = new AiQualityRequirement { RequireCitations = true, Strict = true },
                OnDegradation = AiDegradationPreference.Fail,
            }),
            Attestation());

        Assert.True(uncitable.RequiresHumanDecision, uncitable.Reason);
        Assert.Equal(AiGovernanceRules.EvaluationQualityUnevidenced, uncitable.RuleId);

        // CONTROL: with a source to cite, the same requirement is satisfied.
        Assert.True(evaluator.Evaluate(
            Request(
                context: [DataClassification.Public],
                execution: new AiExecutionPolicy
                {
                    Quality = new AiQualityRequirement { RequireCitations = true, Strict = true },
                    OnDegradation = AiDegradationPreference.Fail,
                }),
            Attestation()).IsAllowed);
    }

    [Fact]
    public void CapabilityNotInTheRegister_IsRefused_WithTheCapabilityNotFoundCategory()
    {
        var evaluator = Evaluator(Policy());

        var decision = evaluator.Evaluate(
            Request(capability: "product.pricing.recommend"),
            Attestation());

        Assert.True(decision.IsBlocked);
        Assert.Equal(AiGovernanceRules.CapabilityNotServable, decision.RuleId);
        Assert.Equal(AiFailureCategory.CapabilityNotFound, decision.FailureCategory);
    }

    // The applied-rule list is what a reviewer uses to answer "what else was true about this request",
    // so a decision must never claim a rule that did not fire - and a refusal must not read as though
    // something permitted it.
    [Fact]
    public void AnAllowedDecision_CarriesNoRefusalRule_AndABlockCarriesNoAllowedRule()
    {
        var evaluator = Evaluator(Policy());

        var allowed = evaluator.Evaluate(Request(), Attestation());

        Assert.True(allowed.IsAllowed);
        Assert.Equal(AiGovernanceRules.Allowed, allowed.RuleId);

        // Nothing refused: no member of the governance vocabulary is in the applied set of an allowed
        // decision. Stated as an intersection rather than as an exact list, because the applied set is a
        // trace over three namespaces (governance rules, the platform authority, the exposure table's own
        // rows) and an exact-equality assertion here would pin the exposure engine's formatting, which is
        // not this lane's to pin.
        Assert.Empty(allowed.RulesApplied.Intersect(AiGovernanceRules.All, StringComparer.Ordinal));

        // The authority that attested is recorded. None means no platform action was attached, which
        // says the execution was attached to nothing rather than that something permitted it - the
        // distinction that makes this entry worth carrying.
        Assert.Contains(AiGovernanceAuthority.None, allowed.RulesApplied);

        // And no entry is a refusal rule, so an allowed decision cannot read as one that refused.
        Assert.DoesNotContain(AiGovernanceRules.ProhibitedSurface, allowed.RulesApplied);
        Assert.DoesNotContain(AiGovernanceRules.ExposureBlocked, allowed.RulesApplied);

        var blocked = evaluator.Evaluate(
            Request(touchesSurface: AiProhibitedSurface.SecretCustody),
            Attestation());

        Assert.True(blocked.IsBlocked);
        Assert.Equal(AiGovernanceRules.ProhibitedSurface, blocked.RuleId);

        // A refusal does not also claim something permitted it, which is what the allowed sentinel would
        // say if it were seeded into the accumulator rather than added at the end for an allowed decision.
        Assert.DoesNotContain(AiGovernanceRules.Allowed, blocked.RulesApplied);
        Assert.Contains(AiGovernanceRules.ProhibitedSurface, blocked.RulesApplied);
    }

    // The contract states that RuleId is always a member of the governance vocabulary. Asserted over
    // every verdict shape rather than for one, because "the deciding rule is a governance rule" is the
    // property a consumer relies on when it switches on the identifier or looks up the rule's text.
    [Fact]
    public void RuleId_IsAlwaysAMemberOfTheGovernanceVocabulary()
    {
        var evaluator = Evaluator(Policy(
            budgets: [Budget("budget.code.review", 0.50m)],
            tools: [Tool("code.analysis.run", ToolSideEffectClass.Write, requiresHumanApproval: true)]));

        var decisions = new[]
        {
            evaluator.Evaluate(Request(), Attestation()),
            evaluator.Evaluate(Request(touchesSurface: AiProhibitedSurface.SecretCustody), Attestation()),
            evaluator.Evaluate(
                Request(classification: DataClassification.Secret), Attestation()),
            evaluator.Evaluate(
                Request(estimatedCost: 0.75m, execution: Priced(0.75m)), Attestation()),
            evaluator.Evaluate(
                Request(
                    tools: Profile(["code.analysis.run"], ToolSideEffectClass.Write),
                    toolIds: ["code.analysis.run"],
                    permissionScope: new AiPermissionScope { MayCauseSideEffects = true }),
                Attestation()),
            evaluator.Evaluate(
                Request(),
                AiPlatformGovernanceAttestation.Refuse(AiGovernanceAuthority.Deployment, "Closed.")),
        };

        // All three verdicts are represented, so the sweep above is not three copies of ALLOW.
        Assert.Contains(decisions, d => d.IsAllowed);
        Assert.Contains(decisions, d => d.IsBlocked);

        foreach (var decision in decisions)
        {
            Assert.True(
                AiGovernanceRules.IsKnown(decision.RuleId),
                $"RuleId '{decision.RuleId}' is not a member of the governance vocabulary "
                + $"(verdict {decision.Verdict}).");
        }
    }

    // And the counterpart, which is the reason the field's remarks exist: RulesApplied does NOT share
    // that property - it is a trace over five namespaces, not a set of vocabulary members. Each kind is
    // asserted to appear, because this list is what an auditor reads and a consumer that filtered it by
    // vocabulary membership would silently drop the other four. The field's remarks name the five kinds;
    // this test is what keeps that list honest when a rule is added or a stage changes.
    [Fact]
    public void RulesApplied_CarriesAllFiveDocumentedKindsOfEntry()
    {
        // Kind 1: a member of the governance vocabulary, from a declared escalation.
        var escalated = Evaluator(Policy(escalations:
        [
            new AiGovernanceEscalationRule
            {
                RuleId = "escalate.code.review",
                Subject = AiGovernanceSubject.Evaluation,
                Reason = "Recorded for the W7B applied-rule fixtures.",
            },
        ])).Evaluate(Request(), Attestation());

        Assert.True(escalated.RequiresHumanDecision, escalated.Reason);
        Assert.Contains(AiGovernanceRules.EscalationDeclared, escalated.RulesApplied);
        Assert.True(AiGovernanceRules.IsKnown(AiGovernanceRules.EscalationDeclared));

        // A second evaluator without the escalation, because an escalated decision is not an allowed one
        // and the remaining assertions are about an execution that nothing refused.
        var evaluator = Evaluator(Policy());
        var allowed = evaluator.Evaluate(Request(), Attestation());

        Assert.True(allowed.IsAllowed, allowed.Reason);

        // Kind 2: a platform authority identifier, recording that no platform action was attached.
        Assert.Contains(AiGovernanceAuthority.None, allowed.RulesApplied);

        // Kind 5: the data-exposure table's own trace of the row it applied.
        Assert.Contains(
            allowed.RulesApplied,
            entry => entry.StartsWith($"{DataClassification.Internal}->", StringComparison.Ordinal));

        // Kind 3: the RuleId of a POLICY RECORD supplied by configuration - not knowable to this contract,
        // and therefore not a vocabulary member.
        var overBudget = Evaluator(Policy(budgets: [Budget("budget.code.review", 0.50m)]))
            .Evaluate(Request(estimatedCost: 0.75m, execution: Priced(0.75m)), Attestation());

        Assert.True(overBudget.IsBlocked, overBudget.Reason);
        Assert.Contains("budget.code.review", overBudget.RulesApplied);
        Assert.False(AiGovernanceRules.IsKnown("budget.code.review"));

        // Kind 4: an enum member name, recording which value of a closed set the decision turned on.
        var prohibited = evaluator.Evaluate(
            Request(touchesSurface: AiProhibitedSurface.SecretCustody),
            Attestation());

        Assert.True(prohibited.IsBlocked);
        Assert.Contains(nameof(AiProhibitedSurface.SecretCustody), prohibited.RulesApplied);
        Assert.False(AiGovernanceRules.IsKnown(nameof(AiProhibitedSurface.SecretCustody)));

        // Four of the five kinds are outside the vocabulary, which is the fact the remarks exist to state.
        var nonVocabulary = allowed.RulesApplied
            .Concat(overBudget.RulesApplied)
            .Concat(prohibited.RulesApplied)
            .Where(entry => !AiGovernanceRules.IsKnown(entry))
            .Distinct(StringComparer.Ordinal)
            .ToArray();

        Assert.NotEmpty(nonVocabulary);

        // And the supported way to ask "which governance rules fired" is an intersection with the
        // vocabulary, which is how a consumer gets that answer without parsing the other four kinds.
        Assert.Equal(
            [AiGovernanceRules.EscalationDeclared],
            escalated.RulesApplied.Intersect(AiGovernanceRules.All, StringComparer.Ordinal));

        // The control: an allowed execution with no escalation has an EMPTY intersection, so the assertion
        // above is the escalation and not the intersection always finding something.
        Assert.Empty(allowed.RulesApplied.Intersect(AiGovernanceRules.All, StringComparer.Ordinal));
    }

    // A priced execution that passes every ceiling must not carry a budget-exceeded rule in its applied
    // set. Asserted because an accumulator seeded with the refusal rule produced exactly that defect
    // during development: an allowed decision whose audit record claimed its budget was exceeded.
    [Fact]
    public void AnAllowedPricedExecution_DoesNotClaimItsBudgetWasExceeded()
    {
        var evaluator = Evaluator(Policy(budgets: [Budget("budget.code.review", 10m)]));

        var decision = evaluator.Evaluate(
            Request(estimatedCost: 1m, execution: Priced(1m)),
            Attestation());

        Assert.True(decision.IsAllowed, decision.Reason);
        Assert.DoesNotContain(AiGovernanceRules.BudgetExceeded, decision.RulesApplied);
        Assert.DoesNotContain(AiGovernanceRules.BudgetUncovered, decision.RulesApplied);
    }

    // =============================================================================================
    // Helpers.
    // =============================================================================================

    private const string CorrelationId = "corr-w7b";

    private static AiPlatformGovernanceAttestation Attestation() => AiPlatformGovernanceAttestation.NotApplicable;

    private static DeterministicAiGovernanceEvaluator Evaluator(
        AiGovernancePolicy policy,
        AiCapabilityRegister? capabilityRegister = null)
        => new(capabilityRegister is null ? policy : policy with { Capabilities = capabilityRegister });

    private static AiGovernancePolicy Policy(
        IAiGovernanceRegister? register = null,
        AiDependencyRegistry? dependencies = null,
        IReadOnlyList<AiGovernanceBudgetRule>? budgets = null,
        IReadOnlyList<AiGovernanceToolRule>? tools = null,
        IReadOnlyList<AiGovernanceEscalationRule>? escalations = null,
        AiProviderTrustTier minTrust = AiProviderTrustTier.Approved,
        bool requireBudgetRuleForPricedExecution = true) => new()
        {
            Dependencies = dependencies ?? AiDependencyRegistry.Empty,
            Capabilities = AiCapabilityRegister.Bootstrap(),
            Exposure = DataExposurePolicy.Default(),
            Register = register ?? EmptyAiGovernanceRegister.Instance,
            Budgets = budgets ?? [],
            Tools = tools ?? [],
            Escalations = escalations ?? [],
            MinimumTrustForRemoteEgress = minTrust,
            RequireBudgetRuleForPricedExecution = requireBudgetRuleForPricedExecution,
        };

    private static AiGovernanceEvaluationRequest Request(
        string capability = "code.review",
        DataClassification classification = DataClassification.Internal,
        IReadOnlyList<DataClassification>? context = null,
        AiDestinationClass destination = AiDestinationClass.Local,
        AiExecutionPolicy? execution = null,
        ToolPermissionProfile? tools = null,
        IReadOnlyList<string>? toolIds = null,
        string? modelId = null,
        string? providerId = null,
        string? agentId = null,
        string? promptId = null,
        string? promptVersion = null,
        decimal? estimatedCost = null,
        AiPermissionScope? permissionScope = null,
        IReadOnlyList<string>? dataScopes = null,
        AiProhibitedSurface? touchesSurface = null) => new()
        {
            RequestId = "req-w7b",
            Capability = CapabilityId.Parse(capability),
            Requester = new AiRequesterIdentity
            {
                Head = CallingHead.Ai,
                PrincipalId = "principal-w7b",

                // Defaults to None, which is the shape almost every capability should use: no side
                // effects, and approval required if one is ever permitted.
                PermissionScope = permissionScope ?? AiPermissionScope.None,
                DataScopes = dataScopes ?? [],
            },
            Classification = classification,
            ContextClassifications = context ?? [],
            Destination = destination,
            Execution = execution ?? AiExecutionPolicy.Default,
            Tools = tools ?? ToolPermissionProfile.None,
            RequestedToolIds = toolIds ?? [],
            ModelId = modelId,
            ProviderId = providerId,
            AgentId = agentId,
            PromptId = promptId,
            PromptVersion = promptVersion,
            EstimatedCost = estimatedCost,
            CorrelationId = CorrelationId,
            TouchesSurface = touchesSurface,
        };

    private static AiExecutionPolicy Priced(decimal amount, string? currency = "USD") => new()
    {
        Quality = AiQualityRequirement.Complete,
        MaxCost = amount,
        CostCurrency = currency,
    };

    private static AiGovernanceBudgetRule Budget(
        string ruleId,
        decimal ceiling,
        AiGovernanceVerdict onExceeded = AiGovernanceVerdict.Block) => new()
        {
            RuleId = ruleId,
            Ceiling = ceiling,
            Currency = "USD",
            OnExceeded = onExceeded,
            Rationale = "Recorded for the W7B budget fixtures.",
        };

    private static ToolPermissionProfile Profile(
        IReadOnlyList<string> toolIds,
        ToolSideEffectClass maxSideEffect,
        bool requireApprovalForWrites = true) => new()
        {
            AllowedToolIds = toolIds,
            MaxSideEffect = maxSideEffect,
            RequireApprovalForWrites = requireApprovalForWrites,
            MaxToolCalls = 4,
        };

    private static ToolPermissionProfile ReadOnlyWith(int maxToolCalls, params string[] toolIds) => new()
    {
        AllowedToolIds = toolIds,
        MaxSideEffect = ToolSideEffectClass.Read,
        RequireApprovalForWrites = true,
        MaxToolCalls = maxToolCalls,
    };

    private static AiGovernanceToolRule Tool(
        string toolId,
        ToolSideEffectClass sideEffect,
        bool requiresHumanApproval = false) => new()
        {
            RuleId = $"tool.{toolId}",
            ToolId = toolId,
            SideEffect = sideEffect,
            RequiresHumanApproval = requiresHumanApproval,
            Rationale = "Recorded for the W7B tool-permission fixtures.",
        };

    private static AiModelGovernanceRecord Model(
        string modelId,
        string providerId,
        DataClassification maxClassification = DataClassification.Secret) => new()
        {
            ModelId = modelId,
            ProviderId = providerId,
            Status = AiGovernanceApprovalStatus.Approved,
            MaxClassification = maxClassification,
            Rationale = "Recorded for the W7B resource fixtures.",
        };

    private static AiProviderGovernanceRecord Provider(
        string providerId,
        bool permitsEgress,
        AiProviderTrustTier trust,
        DataClassification maxClassification = DataClassification.Secret) => new()
        {
            ProviderId = providerId,
            Status = AiGovernanceApprovalStatus.Approved,
            Trust = trust,
            PermitsRemoteEgress = permitsEgress,
            MaxClassification = maxClassification,
            Rationale = "Recorded for the W7B security fixtures.",
        };

    private static TestRegister Governed() => new();

    private static AiCapabilityRegister Register(
        CapabilityId capability,
        AiDependencyClass dependencyClass = AiDependencyClass.AiEnhanced)
        => new(
        [
            .. AiCapabilityRegister.Bootstrap().List(),
            new AiCapabilityRegistration
            {
                Capability = capability,
                Description = "Recorded for the W7B prohibition fixtures.",
                DependencyClass = dependencyClass,
                Owner = "AI-03 AI Governance",
                DependencyRationale = "Recorded for the W7B prohibition fixtures.",
            },
        ]);

    private static readonly Dictionary<AiProhibitedSurface, string> BaselineFeatures = new()
    {
        [AiProhibitedSurface.PlatformGovernanceAuthority] = "platform.governance.authority",
        [AiProhibitedSurface.ProtectedGitMergeAuthority] = "platform.git.merge.authority",
        [AiProhibitedSurface.SecretCustody] = "platform.secret.custody",
        [AiProhibitedSurface.CredentialMaterial] = "platform.credential.material",
        [AiProhibitedSurface.DeterministicSecurityGate] = "platform.security.gate",
    };

    private static IEnumerable<AiDependencyDeclaration> BaselineDeclarations()
        => AiProhibitionBaseline.RequiredSurfaces.Select(surface => Declaration(
            BaselineFeatures[surface],
            surface));

    private static AiDependencyDeclaration Declaration(
        string featureId,
        AiProhibitedSurface surface,
        CapabilityId? capability = null) => new()
        {
            FeatureId = featureId,
            Owner = "Platform",
            DependencyClass = AiDependencyClass.AiProhibited,
            Rationale = "Recorded for the W7B prohibition fixtures.",
            ProhibitedSurface = surface,
            Capability = capability,
        };

    private static AiGovernanceDecision Decision(AiGovernanceVerdict verdict, string ruleId) => verdict switch
    {
        AiGovernanceVerdict.Allow => AiGovernanceDecision.Allow(),
        AiGovernanceVerdict.HumanDecisionRequired => AiGovernanceDecision.HumanDecisionRequired(ruleId, "Fixture."),
        _ => AiGovernanceDecision.Block(ruleId, "Fixture.", AiFailureCategory.PolicyBlocked),
    };

    // A register whose membership is stated by the fixture rather than by the engine. Written as a test
    // double rather than as a production type so that the production register port stays the only thing
    // the engine knows about membership.
    private sealed class TestRegister : IAiGovernanceRegister
    {
        private readonly Dictionary<string, AiModelGovernanceRecord> _models = new(StringComparer.Ordinal);
        private readonly Dictionary<string, AiProviderGovernanceRecord> _providers = new(StringComparer.Ordinal);
        private readonly Dictionary<string, AiAgentGovernanceRecord> _agents = new(StringComparer.Ordinal);
        private readonly Dictionary<string, AiPromptGovernanceRecord> _prompts = new(StringComparer.Ordinal);

        public TestRegister WithModel(AiModelGovernanceRecord record)
        {
            _models[record.ModelId] = record;
            return this;
        }

        public TestRegister WithProvider(AiProviderGovernanceRecord record)
        {
            _providers[record.ProviderId] = record;
            return this;
        }

        public TestRegister WithAgent(AiAgentGovernanceRecord record)
        {
            _agents[record.AgentId] = record;
            return this;
        }

        public TestRegister WithPrompt(AiPromptGovernanceRecord record)
        {
            _prompts[record.PromptId] = record;
            return this;
        }

        public bool TryResolveModel(string? modelId, out AiModelGovernanceRecord? record)
        {
            record = null;
            return modelId is not null && _models.TryGetValue(modelId, out record);
        }

        public bool TryResolveProvider(string? providerId, out AiProviderGovernanceRecord? record)
        {
            record = null;
            return providerId is not null && _providers.TryGetValue(providerId, out record);
        }

        public bool TryResolveAgent(string? agentId, out AiAgentGovernanceRecord? record)
        {
            record = null;
            return agentId is not null && _agents.TryGetValue(agentId, out record);
        }

        public bool TryResolvePrompt(string? promptId, out AiPromptGovernanceRecord? record)
        {
            record = null;
            return promptId is not null && _prompts.TryGetValue(promptId, out record);
        }
    }
}
