namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The AI Head's governance engine: a total, deterministic function from a proposed execution and a
/// platform determination to a verdict.
/// </summary>
/// <remarks>
/// <para>
/// <b>How BLOCK and HUMAN_DECISION_REQUIRED differ, and this is the whole semantics.</b> A
/// <c>BLOCK</c> means <em>the request must change</em>: a protected surface is involved, a resource is
/// unapproved, a classification may not reach the destination, a budget ceiling is exceeded, the
/// request contradicts itself. No person can resolve it by deciding, because there is nothing to
/// decide — the remedy is a different request, an approval written into the register, or a policy
/// record changed by its owner. A <c>HUMAN_DECISION_REQUIRED</c> means <em>a named person must
/// choose</em>: a side-effecting tool call under an approval requirement, a budget overage the owner
/// has declared is a judgement call, a declared escalation. The distinction is enforced by the engine
/// rather than left to a reader, because the failure mode of blurring it is a person being invited to
/// grant what a deterministic rule refused.
/// </para>
/// <para>
/// <b>Rule order is fixed and the composition is monotone.</b> Rules are evaluated in the order below
/// and combined with <see cref="AiGovernanceDecision.Combine"/>, which keeps the most restrictive
/// verdict. No step can lower a verdict, so a rule evaluated later cannot relax one evaluated earlier —
/// which is what makes the order a readability choice rather than a correctness one, and what makes
/// "a human-required decision cannot become an ALLOW" a property of the type rather than of this
/// method's diligence.
/// </para>
/// <para>
/// <b>Nothing here names a model, a provider, an agent or a tool.</b> Every one of those is resolved
/// through <see cref="AiGovernancePolicy.Register"/> or matched against a policy record. The engine's
/// own vocabulary is the rule identifiers and the domains; membership is data throughout, which is the
/// directive's requirement made structural — there is no list here for a reader to check for a missing
/// entry, because there is no list.
/// </para>
/// <para>
/// <b>Evaluation order, and why each stage is where it is:</b>
/// </para>
/// <list type="number">
/// <item><description>
/// <b>Prohibition and platform authority.</b> First, because these are the stages that keep AI out of
/// surfaces a deterministic authority owns, and a later stage cannot be allowed to reach a decision on
/// a request that should never have been evaluated.
/// </description></item>
/// <item><description>
/// <b>Capability.</b> Whether the work may be done by AI at all, before asking how.
/// </description></item>
/// <item><description>
/// <b>Model and provider.</b> The selection already made by the registry, checked for approval and for
/// its classification ceiling.
/// </description></item>
/// <item><description>
/// <b>Agent and prompt.</b> Who acts, and under which instruction set at which version.
/// </description></item>
/// <item><description>
/// <b>Data exposure and context scope.</b> What content may reach the destination. This is the last
/// stage before any provider call and the one the directive requires to block <em>before</em>
/// invocation.
/// </description></item>
/// <item><description>
/// <b>Security.</b> Provider trust and egress permission, which are properties of the destination the
/// two stages above settled on.
/// </description></item>
/// <item><description>
/// <b>Tools.</b> What the execution may cause.
/// </description></item>
/// <item><description>
/// <b>Cost.</b> What it may spend.
/// </description></item>
/// <item><description>
/// <b>Evaluation quality.</b> Whether the caller's requirement can be evidenced at all.
/// </description></item>
/// <item><description>
/// <b>Escalation.</b> Declared reasons for a human to decide, evaluated last so that a request already
/// blocked is not additionally escalated — a block is terminal and asking a person about it would
/// suggest otherwise.
/// </description></item>
/// </list>
/// </remarks>
public sealed class DeterministicAiGovernanceEvaluator : IAiGovernanceEvaluator
{
    private readonly AiGovernancePolicy _policy;
    private readonly IDataExposurePolicyEvaluator _exposure;

    /// <summary>Builds an evaluator over a policy, using the policy's own exposure table.</summary>
    /// <exception cref="ArgumentException">The policy is malformed.</exception>
    public DeterministicAiGovernanceEvaluator(AiGovernancePolicy policy)
        : this(policy, null)
    {
    }

    /// <summary>Builds an evaluator over a policy and an explicit exposure evaluator.</summary>
    /// <param name="policy">The policy records the engine decides from.</param>
    /// <param name="exposure">
    /// The exposure evaluator to use, or <see langword="null"/> to build the declared-classification
    /// evaluator over <see cref="AiGovernancePolicy.Exposure"/>. Supplied separately so that a lane
    /// which replaces the exposure stage replaces one collaborator rather than the policy type.
    /// </param>
    /// <exception cref="ArgumentException">The policy is malformed.</exception>
    public DeterministicAiGovernanceEvaluator(AiGovernancePolicy policy, IDataExposurePolicyEvaluator? exposure)
    {
        _policy = policy ?? throw new ArgumentNullException(nameof(policy));

        // Validated here, at composition, rather than on the first request that happens to reach the
        // broken record. A policy that is wrong is wrong for every request; discovering it per-request
        // converts a startup failure into a production one.
        _policy.Validate();

        _exposure = exposure ?? new DeclaredClassificationExposureEvaluator(policy.Exposure);
    }

    /// <summary>The policy this engine decides from.</summary>
    public AiGovernancePolicy Policy => _policy;

    /// <inheritdoc />
    public AiGovernanceDecision Evaluate(
        AiGovernanceEvaluationRequest request,
        AiPlatformGovernanceAttestation platform)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(platform);

        var applied = new List<string>();
        var decision = AiGovernanceDecision.Allow();

        void Record(AiGovernanceDecision next)
        {
            applied.AddRange(next.RulesApplied);
            decision = decision.Combine(next);
        }

        // -----------------------------------------------------------------------------------------
        // 1. Prohibition and platform authority.
        // -----------------------------------------------------------------------------------------

        Record(EvaluateProhibition(request));
        Record(EvaluatePlatformAuthority(platform));

        // Nothing below this line can produce an ALLOW over a block: Record composes most-restrictively,
        // so a prohibition cannot be undone by a later stage that happens to find everything in order.

        // -----------------------------------------------------------------------------------------
        // 2. Capability.
        // -----------------------------------------------------------------------------------------

        Record(EvaluateCapability(request));

        // -----------------------------------------------------------------------------------------
        // 3. Model and provider.
        // -----------------------------------------------------------------------------------------

        var model = ResolveModel(request);
        var provider = ResolveProvider(request);

        Record(EvaluateModel(request, model));
        Record(EvaluateProvider(request, provider));

        // -----------------------------------------------------------------------------------------
        // 4. Agent and prompt.
        // -----------------------------------------------------------------------------------------

        Record(EvaluateAgent(request));
        Record(EvaluatePrompt(request));

        // -----------------------------------------------------------------------------------------
        // 5. Data exposure and context scope. The stage the directive requires to be able to refuse
        //    before any provider is invoked.
        // -----------------------------------------------------------------------------------------

        Record(EvaluateExposure(request));
        Record(EvaluateContextScope(request));

        // -----------------------------------------------------------------------------------------
        // 6. Security.
        // -----------------------------------------------------------------------------------------

        Record(EvaluateSecurity(request, provider));

        // -----------------------------------------------------------------------------------------
        // 7. Tools.
        // -----------------------------------------------------------------------------------------

        Record(EvaluateTools(request));

        // -----------------------------------------------------------------------------------------
        // 8. Cost.
        // -----------------------------------------------------------------------------------------

        Record(EvaluateCost(request));

        // -----------------------------------------------------------------------------------------
        // 9. Evaluation quality.
        // -----------------------------------------------------------------------------------------

        Record(EvaluateQuality(request));

        // -----------------------------------------------------------------------------------------
        // 10. Escalation.
        // -----------------------------------------------------------------------------------------

        Record(EvaluateEscalation(request, decision));

        var rules = applied.Distinct(StringComparer.Ordinal).ToArray();

        // "No rule fired" is recorded as the allowed rule rather than as an empty list, so a reader of
        // the audit record can tell a governed execution that nothing refused from a record whose rule
        // list was never populated. On a refusal the allowed rule is NOT added: a block whose applied
        // list contained 'governance.allowed' would read as a decision that both permitted and refused.
        return decision.IsAllowed && rules.Length == 0
            ? decision with { RulesApplied = [AiGovernanceRules.Allowed] }
            : decision with { RulesApplied = rules };
    }

    // =============================================================================================
    // 1. Prohibition and platform authority
    // =============================================================================================

    private AiGovernanceDecision EvaluateProhibition(AiGovernanceEvaluationRequest request)
    {
        if (request.TouchesSurface is { } surface)
        {
            // The baseline surfaces are refused STRUCTURALLY, from AiProhibitionBaseline, and not by
            // asking the register. That distinction is the difference between a control and a lookup:
            // AiDependencyRegistry.Empty covers no surface, so a register-driven check would permit AI
            // participation in Platform Governance authority on any estate whose register had not been
            // populated yet. The baseline is the deterministic authority's own standing statement, and
            // it does not depend on anyone having written a record.
            if (AiProhibitionBaseline.IsRequired(surface))
            {
                return AiGovernanceDecision.Block(
                    AiGovernanceRules.ProhibitedSurface,
                    $"AI participation is prohibited on the protected surface '{surface}'. The deterministic "
                    + "path is the only path on this surface; AI may advise a person, it may not be in the "
                    + "decision path.",
                    AiFailureCategory.PolicyBlocked,
                    AiGovernanceRules.ProhibitedSurface,
                    surface.ToString());
            }

            // The open-ended surface, and here the register IS the authority: which Product capabilities
            // are prohibited is a fact only the declaring Head or Product can supply, so this one is
            // asked rather than assumed. Naming a surface can therefore only ever refuse more.
            if (!_policy.Dependencies.MayAiParticipate(surface))
            {
                return AiGovernanceDecision.Block(
                    AiGovernanceRules.ProhibitedSurface,
                    $"AI participation is prohibited on '{surface}' by a declaration in the dependency "
                    + "register. The declaration names the surface, so the prohibition applies whether or "
                    + "not the declaring feature is enabled.",
                    AiFailureCategory.PolicyBlocked,
                    AiGovernanceRules.ProhibitedSurface,
                    surface.ToString());
            }
        }

        if (_policy.Dependencies.IsCapabilityProhibited(request.Capability))
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ProhibitedCapability,
                $"Capability '{request.Capability}' is declared AI-prohibited in the dependency register. "
                + "A prohibited capability has no AI path at all — not a degraded one, not a labelled one.",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.ProhibitedCapability);
        }

        return AiGovernanceDecision.Allow();
    }

    private AiGovernanceDecision EvaluatePlatformAuthority(AiPlatformGovernanceAttestation platform)
    {
        // The platform's own surface. An attestation that names a protected surface is an attestation
        // about a decision AI may not participate in, so AI is refused regardless of what the platform
        // determined — the platform permitting it does not authorise AI to be in the loop, and refusing
        // it is the whole content of "AI Governance may not override Platform Governance".
        if (platform.AuthorityConsulted && platform.Surface is { } surface && AiProhibitionBaseline.IsRequired(surface))
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ProhibitedSurface,
                $"The action under evaluation belongs to the protected surface '{surface}'. AI does not "
                + "participate in it, so no AI verdict is available for it in either direction.",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.ProhibitedSurface,
                platform.AuthorityId);
        }

        if (platform.Verdict.IsRefusal())
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.PlatformAuthorityRefused,
                platform.Reason
                ?? $"Deterministic Platform Governance refused the action this execution belongs to "
                   + $"('{platform.AuthorityId}').",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.PlatformAuthorityRefused,
                platform.AuthorityId);
        }

        // Consulted or not, the subordination is applied by composition below; here the attestation
        // contributes only its rule identifier, so the audit record shows whether a platform authority
        // was actually consulted or that no platform action was attached.
        return AiGovernanceDecision.Allow(
            platform.AuthorityConsulted ? AiGovernanceRules.PlatformAuthorityAttested : platform.AuthorityId);
    }

    // =============================================================================================
    // 2. Capability
    // =============================================================================================

    private AiGovernanceDecision EvaluateCapability(AiGovernanceEvaluationRequest request)
    {
        if (!_policy.Capabilities.TryResolve(request.Capability, out var registration) || registration is null)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.CapabilityNotServable,
                $"Capability '{request.Capability}' is not registered and enabled, so there is nothing for "
                + "governance to permit.",
                AiFailureCategory.CapabilityNotFound,
                AiGovernanceRules.CapabilityNotServable);
        }

        if (registration.DependencyClass is AiDependencyClass.AiProhibited)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.CapabilityDependencyProhibited,
                $"Capability '{request.Capability}' is declared '{AiDependencyClass.AiProhibited}'. A "
                + "prohibited capability has no AI path to permit, degraded or otherwise.",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.CapabilityDependencyProhibited);
        }

        return AiGovernanceDecision.Allow();
    }

    // =============================================================================================
    // 3. Model and provider
    // =============================================================================================

    private AiModelGovernanceRecord? ResolveModel(AiGovernanceEvaluationRequest request)
        => _policy.Register.TryResolveModel(request.ModelId, out var record) ? record : null;

    private AiProviderGovernanceRecord? ResolveProvider(AiGovernanceEvaluationRequest request)
        => _policy.Register.TryResolveProvider(request.ProviderId, out var record) ? record : null;

    private static AiGovernanceDecision EvaluateModel(
        AiGovernanceEvaluationRequest request,
        AiModelGovernanceRecord? model)
    {
        if (request.ModelId is null)
        {
            // A remote execution must name the model that will serve it, because governance cannot
            // approve a selection it was not told about. "Unnamed" is refused rather than skipped: a
            // skip would let an execution reach a provider with nothing having checked whether the
            // model receiving the content is cleared for it.
            return request.Destination is AiDestinationClass.RemoteProvider
                ? AiGovernanceDecision.Block(
                    AiGovernanceRules.ModelUnregistered,
                    "The execution would reach a remote provider but names no model, so no model approval "
                    + "can be resolved for it.",
                    AiFailureCategory.PolicyBlocked,
                    AiGovernanceRules.ModelUnregistered)
                : AiGovernanceDecision.Allow();
        }

        if (model is null)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ModelUnregistered,
                $"Model '{request.ModelId}' is not in the governance register. An unregistered model is "
                + "refused rather than permitted by default: absence of a record is not an approval, and "
                + "treating it as one would make the register's coverage a matter of what nobody wrote.",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.ModelUnregistered);
        }

        if (model.Status is not AiGovernanceApprovalStatus.Approved)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ModelNotApproved,
                $"Model '{model.ModelId}' is '{model.Status}' and may not be used. {model.Rationale}",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.ModelNotApproved,
                model.Status.ToString());
        }

        if (request.Classification > model.MaxClassification)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ModelClassificationCeiling,
                $"Model '{model.ModelId}' is cleared to receive up to '{model.MaxClassification}' and the "
                + $"request is classified '{request.Classification}'.",
                AiFailureCategory.DataExposureBlocked,
                AiGovernanceRules.ModelClassificationCeiling);
        }

        return AiGovernanceDecision.Allow();
    }

    private static AiGovernanceDecision EvaluateProvider(
        AiGovernanceEvaluationRequest request,
        AiProviderGovernanceRecord? provider)
    {
        if (request.ProviderId is null)
        {
            return request.Destination is AiDestinationClass.RemoteProvider
                ? AiGovernanceDecision.Block(
                    AiGovernanceRules.ProviderUnregistered,
                    "The execution would reach a remote provider but names none, so no provider approval "
                    + "can be resolved for it.",
                    AiFailureCategory.PolicyBlocked,
                    AiGovernanceRules.ProviderUnregistered)
                : AiGovernanceDecision.Allow();
        }

        if (provider is null)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ProviderUnregistered,
                $"Provider '{request.ProviderId}' is not in the governance register. An unregistered "
                + "provider is refused rather than permitted by default.",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.ProviderUnregistered);
        }

        if (provider.Status is not AiGovernanceApprovalStatus.Approved)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ProviderNotApproved,
                $"Provider '{provider.ProviderId}' is '{provider.Status}' and may not be used. "
                + provider.Rationale,
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.ProviderNotApproved,
                provider.Status.ToString());
        }

        // The provider's own ceiling, and its own rule identifier: a provider and a model are assessed
        // separately, so an audit record must be able to say which of the two ceilings was hit.
        if (request.Classification > provider.MaxClassification)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ProviderClassificationCeiling,
                $"Provider '{provider.ProviderId}' is cleared to receive up to "
                + $"'{provider.MaxClassification}' and the request is classified '{request.Classification}'.",
                AiFailureCategory.DataExposureBlocked,
                AiGovernanceRules.ProviderClassificationCeiling);
        }

        return AiGovernanceDecision.Allow();
    }

    // =============================================================================================
    // 4. Agent and prompt
    // =============================================================================================

    private AiGovernanceDecision EvaluateAgent(AiGovernanceEvaluationRequest request)
    {
        if (request.AgentId is null)
        {
            return AiGovernanceDecision.Allow();
        }

        if (!_policy.Register.TryResolveAgent(request.AgentId, out var agent) || agent is null)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.AgentUnregistered,
                $"Agent '{request.AgentId}' is not in the governance register. An unregistered agent is "
                + "refused rather than permitted by default.",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.AgentUnregistered);
        }

        if (agent.Status is not AiGovernanceApprovalStatus.Approved)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.AgentNotApproved,
                $"Agent '{agent.AgentId}' is '{agent.Status}' and may not act. {agent.Rationale}",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.AgentNotApproved,
                agent.Status.ToString());
        }

        if (!agent.AllowedCapabilities.Contains(request.Capability))
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.AgentCapabilityNotPermitted,
                $"Agent '{agent.AgentId}' is not approved for capability '{request.Capability}'. An "
                + "agent's authority is a grant of specific work, so an unlisted capability is refused "
                + "rather than assumed to be within its remit.",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.AgentCapabilityNotPermitted);
        }

        var profile = request.Tools ?? ToolPermissionProfile.None;

        if (profile.MaxSideEffect > agent.MaxSideEffect)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ToolSideEffectExceeded,
                $"The requested tool profile permits side effects up to '{profile.MaxSideEffect}' "
                + $"and agent '{agent.AgentId}' may cause at most '{agent.MaxSideEffect}'. Both ceilings "
                + "apply; the narrower one wins.",
                AiFailureCategory.ToolPermissionDenied,
                AiGovernanceRules.ToolSideEffectExceeded);
        }

        return AiGovernanceDecision.Allow();
    }

    private AiGovernanceDecision EvaluatePrompt(AiGovernanceEvaluationRequest request)
    {
        if (request.PromptId is null)
        {
            return AiGovernanceDecision.Allow();
        }

        if (string.IsNullOrWhiteSpace(request.PromptVersion))
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.PromptUnversioned,
                $"Prompt '{request.PromptId}' is to be applied with no version stated, so the execution "
                + "could not be reproduced from its own audit record. A prompt is the artefact that most "
                + "directly steers the model and the one most likely to be edited in place.",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.PromptUnversioned);
        }

        if (!_policy.Register.TryResolvePrompt(request.PromptId, out var prompt) || prompt is null)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.PromptUnregistered,
                $"Prompt '{request.PromptId}' is not in the governance register. An unregistered prompt is "
                + "refused rather than permitted by default.",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.PromptUnregistered);
        }

        if (prompt.Status is not AiGovernanceApprovalStatus.Approved)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.PromptNotApproved,
                $"Prompt '{prompt.PromptId}' is '{prompt.Status}' and may not be applied. {prompt.Rationale}",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.PromptNotApproved,
                prompt.Status.ToString());
        }

        if (!string.Equals(prompt.ApprovedVersion, request.PromptVersion, StringComparison.Ordinal))
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.PromptNotApproved,
                $"Prompt '{prompt.PromptId}' is approved at version '{prompt.ApprovedVersion}' and version "
                + $"'{request.PromptVersion}' was requested. An unreviewed version of an approved prompt is "
                + "an unapproved prompt.",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.PromptNotApproved);
        }

        return AiGovernanceDecision.Allow();
    }

    // =============================================================================================
    // 5. Data exposure and context scope
    // =============================================================================================

    private AiGovernanceDecision EvaluateExposure(AiGovernanceEvaluationRequest request)
    {
        var exposure = _exposure.Evaluate(
            request.Classification,
            request.ContextClassifications,
            request.Destination);

        if (exposure.Allowed)
        {
            return AiGovernanceDecision.Allow(exposure.RulesApplied.ToArray());
        }

        // The failure category is DataExposureBlocked and not PolicyBlocked, for the reason
        // DataExposureDecision.ToFailure gives: "this data may not go there" is answered by
        // re-classifying or by accepting a local destination, whereas "this action is not permitted"
        // is not. Handing a caller one category for both makes it apply the wrong remedy.
        return AiGovernanceDecision.Block(
            AiGovernanceRules.ExposureBlocked,
            exposure.Reason ?? $"Content classified '{request.Classification}' may not reach a "
                               + $"'{request.Destination}' destination.",
            AiFailureCategory.DataExposureBlocked,
            [.. exposure.RulesApplied, AiGovernanceRules.ExposureBlocked]);
    }

    private static AiGovernanceDecision EvaluateContextScope(AiGovernanceEvaluationRequest request)
    {
        if (request.ContextClassifications.Count == 0)
        {
            return AiGovernanceDecision.Allow();
        }

        var ceiling = DataClassificationExtensions.Aggregate(request.ContextClassifications);

        if (ceiling is DataClassification.Public)
        {
            return AiGovernanceDecision.Allow();
        }

        if (request.Requester.DataScopes.Count == 0)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ContextScopeUndeclared,
                $"The execution supplies context classified up to '{ceiling}' and the requester declared "
                + "no data scope. A classification is an assertion about content; the scope is the "
                + "assertion about where it came from, and governance cannot check one against the other "
                + "when only one was supplied.",
                AiFailureCategory.DataExposureBlocked,
                AiGovernanceRules.ContextScopeUndeclared);
        }

        return AiGovernanceDecision.Allow();
    }

    // =============================================================================================
    // 6. Security
    // =============================================================================================

    private AiGovernanceDecision EvaluateSecurity(
        AiGovernanceEvaluationRequest request,
        AiProviderGovernanceRecord? provider)
    {
        if (request.Destination is not AiDestinationClass.RemoteProvider || provider is null)
        {
            return AiGovernanceDecision.Allow();
        }

        if (!provider.PermitsRemoteEgress)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.SecurityEgressNotPermitted,
                $"Provider '{provider.ProviderId}' is not permitted to receive content over the network. "
                + "This is a property of the provider's approval, not of the content: a local destination "
                + "remains available.",
                AiFailureCategory.DataExposureBlocked,
                AiGovernanceRules.SecurityEgressNotPermitted);
        }

        if (provider.Trust < _policy.MinimumTrustForRemoteEgress)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.SecurityTrustBelowFloor,
                $"Provider '{provider.ProviderId}' is at trust tier '{provider.Trust}' and the policy "
                + $"requires at least '{_policy.MinimumTrustForRemoteEgress}' for remote egress.",
                AiFailureCategory.DataExposureBlocked,
                AiGovernanceRules.SecurityTrustBelowFloor);
        }

        return AiGovernanceDecision.Allow();
    }

    // =============================================================================================
    // 7. Tools
    // =============================================================================================

    private AiGovernanceDecision EvaluateTools(AiGovernanceEvaluationRequest request)
    {
        var profile = request.Tools ?? ToolPermissionProfile.None;
        var applied = new List<string>();
        var decision = AiGovernanceDecision.Allow();

        void Record(AiGovernanceDecision next)
        {
            applied.AddRange(next.RulesApplied);
            decision = decision.Combine(next);
        }

        // A negative ceiling is refused, not read as "unlimited". The field is documented as a maximum, so
        // a negative value is a malformed profile rather than a licence: treating -1 as no bound would let
        // a single typo disable the runaway-loop bound, which is the failure the bound exists to prevent.
        // The conservative reading of a record that cannot be interpreted is a refusal everywhere else in
        // this engine - an unknown tool, an unregistered model, an uncovered cost - and it is one here too.
        if (profile.MaxToolCalls < 0)
        {
            Record(AiGovernanceDecision.Block(
                AiGovernanceRules.ToolCallCeilingExceeded,
                $"The tool profile carries a negative call ceiling ({profile.MaxToolCalls}), which is not a "
                + "maximum, so no call count can be checked against it.",
                AiFailureCategory.ToolPermissionDenied,
                AiGovernanceRules.ToolCallCeilingExceeded));
        }
        else if (request.RequestedToolIds.Count > profile.MaxToolCalls)
        {
            Record(AiGovernanceDecision.Block(
                AiGovernanceRules.ToolCallCeilingExceeded,
                $"{request.RequestedToolIds.Count} tool calls were requested and the profile permits at "
                + $"most {profile.MaxToolCalls}.",
                AiFailureCategory.ToolPermissionDenied,
                AiGovernanceRules.ToolCallCeilingExceeded));
        }

        foreach (var toolId in request.RequestedToolIds.Distinct(StringComparer.Ordinal).OrderBy(t => t, StringComparer.Ordinal))
        {
            Record(EvaluateTool(request, profile, toolId));
        }

        return decision with { RulesApplied = applied.Distinct(StringComparer.Ordinal).ToArray() };
    }

    private AiGovernanceDecision EvaluateTool(
        AiGovernanceEvaluationRequest request,
        ToolPermissionProfile profile,
        string toolId)
    {
        if (!profile.AllowedToolIds.Contains(toolId, StringComparer.Ordinal))
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ToolNotPermitted,
                $"Tool '{toolId}' is not in the execution's tool permission profile. A profile lists what "
                + "is permitted, so an unlisted tool is refused rather than assumed harmless.",
                AiFailureCategory.ToolPermissionDenied,
                AiGovernanceRules.ToolNotPermitted);
        }

        var rule = _policy.ToolFor(toolId);

        if (rule is null)
        {
            // Unknown is more severe than any known class. The failure mode of a tool register is a
            // newly registered tool being permitted because nobody classified it, and treating
            // ignorance as the worst case inverts that failure mode rather than accepting it.
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ToolUnknown,
                $"Tool '{toolId}' is not in the governance tool register, so its effect is unknown. An "
                + "unclassified tool is refused: permitting it would make the register's coverage the "
                + "only thing standing between a tool and its effect.",
                AiFailureCategory.ToolPermissionDenied,
                AiGovernanceRules.ToolUnknown);
        }

        if (rule.SideEffect > profile.MaxSideEffect)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ToolSideEffectExceeded,
                $"Tool '{toolId}' has side-effect class '{rule.SideEffect}' and the profile ceiling is "
                + $"'{profile.MaxSideEffect}'. Both must permit; the ceiling is what stops a newly "
                + "registered tool being permitted by omission from a list.",
                AiFailureCategory.ToolPermissionDenied,
                AiGovernanceRules.ToolSideEffectExceeded,
                rule.RuleId);
        }

        var causesSideEffects = rule.SideEffect >= ToolSideEffectClass.Write;

        if (causesSideEffects && !request.Requester.PermissionScope.MayCauseSideEffects)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.ToolNotPermitted,
                $"Tool '{toolId}' causes a '{rule.SideEffect}' side effect and the requester may not cause "
                + "side effects at all. The permission to read is not the permission to cause.",
                AiFailureCategory.ToolPermissionDenied,
                AiGovernanceRules.ToolNotPermitted,
                rule.RuleId);
        }

        if (causesSideEffects
            && (profile.RequireApprovalForWrites
                || rule.RequiresHumanApproval
                || request.Requester.PermissionScope.RequiresHumanApprovalForSideEffects))
        {
            return AiGovernanceDecision.HumanDecisionRequired(
                AiGovernanceRules.ToolApprovalRequired,
                $"Tool '{toolId}' causes a '{rule.SideEffect}' side effect and a human must approve the "
                + "call. This is a decision, not a refusal: the tool is permitted and a person must say so.",
                AiGovernanceRules.ToolApprovalRequired,
                rule.RuleId);
        }

        return AiGovernanceDecision.Allow();
    }

    // =============================================================================================
    // 8. Cost
    // =============================================================================================

    private AiGovernanceDecision EvaluateCost(AiGovernanceEvaluationRequest request)
    {
        if (request.EstimatedCost is not { } estimated)
        {
            return AiGovernanceDecision.Allow();
        }

        var applied = new List<string>();
        var decision = AiGovernanceDecision.Allow();

        void Record(AiGovernanceDecision next)
        {
            applied.AddRange(next.RulesApplied);
            decision = decision.Combine(next);
        }

        // The caller's own ceiling first. Exceeding what the caller asked to spend is a refusal, and
        // the caller's stated ceiling is the tightest bound the engine knows about.
        if (request.Execution.MaxCost is { } callerCeiling && estimated > callerCeiling)
        {
            Record(AiGovernanceDecision.Block(
                AiGovernanceRules.BudgetExceeded,
                $"The execution is estimated at {estimated} and the caller's ceiling is {callerCeiling}.",
                AiFailureCategory.BudgetBlocked,
                AiGovernanceRules.BudgetExceeded));
        }

        var rule = _policy.BudgetFor(request.Capability, request.Requester.ProductId);

        if (rule is null)
        {
            if (_policy.RequireBudgetRuleForPricedExecution)
            {
                Record(AiGovernanceDecision.Block(
                    AiGovernanceRules.BudgetUncovered,
                    $"The execution is priced at {estimated} and no budget rule covers capability "
                    + $"'{request.Capability}'. 'No ceiling covers this' and 'this has no ceiling' are the "
                    + "same statement, and the second is a finding.",
                    AiFailureCategory.BudgetBlocked,
                    AiGovernanceRules.BudgetUncovered));
            }

            return decision with { RulesApplied = applied.Distinct(StringComparer.Ordinal).ToArray() };
        }

        // A ceiling is a number with a unit, and two numbers with different units cannot be compared. An
        // absent currency is not a wildcard — it is a number whose unit nobody stated — so it is refused
        // for the same reason a mismatch is, rather than being treated as matching everything.
        if (!string.Equals(request.Execution.CostCurrency, rule.Currency, StringComparison.Ordinal))
        {
            Record(AiGovernanceDecision.Block(
                AiGovernanceRules.BudgetUncovered,
                request.Execution.CostCurrency is { } requestedCurrency
                    ? $"Budget rule '{rule.RuleId}' is denominated in '{rule.Currency}' and the execution "
                      + $"is denominated in '{requestedCurrency}'. A ceiling cannot be enforced across "
                      + "currencies, and comparing them silently is the defect the currency field exists "
                      + "to prevent."
                    : $"Budget rule '{rule.RuleId}' is denominated in '{rule.Currency}' and the execution "
                      + "names no currency, so its cost cannot be compared against the ceiling at all.",
                AiFailureCategory.BudgetBlocked,
                AiGovernanceRules.BudgetUncovered,
                rule.RuleId));

            return decision with { RulesApplied = applied.Distinct(StringComparer.Ordinal).ToArray() };
        }

        if (estimated > rule.Ceiling)
        {
            Record(rule.OnExceeded is AiGovernanceVerdict.HumanDecisionRequired
                ? AiGovernanceDecision.HumanDecisionRequired(
                    AiGovernanceRules.BudgetExceeded,
                    $"The execution is estimated at {estimated} {rule.Currency} and budget rule "
                    + $"'{rule.RuleId}' has a ceiling of {rule.Ceiling} {rule.Currency}. {rule.Rationale}",
                    AiGovernanceRules.BudgetExceeded,
                    rule.RuleId)
                : AiGovernanceDecision.Block(
                    AiGovernanceRules.BudgetExceeded,
                    $"The execution is estimated at {estimated} {rule.Currency} and budget rule "
                    + $"'{rule.RuleId}' has a ceiling of {rule.Ceiling} {rule.Currency}. {rule.Rationale}",
                    AiFailureCategory.BudgetBlocked,
                    AiGovernanceRules.BudgetExceeded,
                    rule.RuleId));
        }

        return decision with { RulesApplied = applied.Distinct(StringComparer.Ordinal).ToArray() };
    }

    // =============================================================================================
    // 9. Evaluation and output risk
    // =============================================================================================

    private static AiGovernanceDecision EvaluateQuality(AiGovernanceEvaluationRequest request)
    {
        if (request.Execution.Quality is not { Strict: true } quality)
        {
            return AiGovernanceDecision.Allow();
        }

        // A strict quality requirement and a silent deterministic fallback are contradictory. Strict
        // means an answer that cannot meet the requirement must fail; ReturnDeterministicResult means
        // the caller wants the absence swallowed. Honouring either clause violates the other, so the
        // request is refused rather than answered — and it is a block rather than an escalation
        // because there is nothing for a person to decide: the remedy is a different request.
        if (request.Execution.OnDegradation is AiDegradationPreference.ReturnDeterministicResult)
        {
            return AiGovernanceDecision.Block(
                AiGovernanceRules.EvaluationQualityUnevidenced,
                "The execution requires a strict quality level and simultaneously asks for a silent "
                + "deterministic fallback. Strict means an answer below the requirement must fail; a "
                + "silent fallback means the caller never learns it did. The request cannot be honoured "
                + "as written in either direction.",
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.EvaluationQualityUnevidenced);
        }

        if (quality.RequireCitations && request.ContextClassifications.Count == 0)
        {
            // A citation points at a context item, so a strict citation requirement with no context
            // supplied cannot be evidenced. A person decides whether to proceed unevidenced or to
            // re-issue the request with the source attached — which is exactly the shape of a decision
            // a human owns, and why this is an escalation rather than a refusal.
            return AiGovernanceDecision.HumanDecisionRequired(
                AiGovernanceRules.EvaluationQualityUnevidenced,
                "The execution requires citations and supplies no context to cite. Either the requirement "
                + "is wrong for this request or the source was not attached; a person must decide which.",
                AiGovernanceRules.EvaluationQualityUnevidenced);
        }

        return AiGovernanceDecision.Allow();
    }

    // =============================================================================================
    // 10. Escalation
    // =============================================================================================

    private AiGovernanceDecision EvaluateEscalation(
        AiGovernanceEvaluationRequest request,
        AiGovernanceDecision current)
    {
        // A block is terminal, so a refused request is not also escalated. Asking a person about a
        // refusal suggests the refusal is theirs to lift, and it is not: the remedy for a block is a
        // different request or a changed record, neither of which is a decision. Escalating a blocked
        // request would also put an escalation rule in the audit record of an execution no human was
        // ever going to be asked about.
        if (current.IsBlocked)
        {
            return AiGovernanceDecision.Allow();
        }

        var applied = new List<string>();
        var decision = AiGovernanceDecision.Allow();

        foreach (var subject in Enum.GetValues<AiGovernanceSubject>())
        {
            foreach (var rule in _policy.EscalationsFor(subject, request.Capability, request.Classification))
            {
                applied.AddRange([AiGovernanceRules.EscalationDeclared, rule.RuleId]);

                decision = decision.Combine(AiGovernanceDecision.HumanDecisionRequired(
                    AiGovernanceRules.EscalationDeclared,
                    $"Governance declares that a human must decide about the '{subject}' domain for this "
                    + $"execution. {rule.Reason}",
                    AiGovernanceRules.EscalationDeclared,
                    rule.RuleId));
            }
        }

        return decision with { RulesApplied = applied.Distinct(StringComparer.Ordinal).ToArray() };
    }
}
