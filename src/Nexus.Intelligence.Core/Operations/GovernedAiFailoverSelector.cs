using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// Walks the router's governed fallback chain, re-reading the operational gates at attempt time.
/// </summary>
/// <remarks>
/// <para>
/// <b>It cannot invent a candidate.</b> The only source of routes is
/// <see cref="AiRoutingOutcome.FallbackChain"/>, which is a slice of
/// <see cref="AiRoutingOutcome.Eligible"/> — every member of which was individually permitted by
/// governance for this exact request, classification and destination. There is no other list on this
/// type and no way to add one, so "a fallback cannot bypass W7B governance" is a property of the
/// shape rather than a check that a later edit could reorder.
/// </para>
/// <para>
/// <b>It may refuse a chain member the router permitted.</b> Health, registration and budget are read
/// again here, because a chain computed before the first attempt is already stale by the time the
/// first attempt fails — and the reason a failover exists at all is that something changed. A route
/// that was healthy, registered and affordable when the chain was built and is none of those now is
/// skipped, with the reason recorded.
/// </para>
/// <para>
/// <b>It stops on a governance refusal rather than routing around one.</b> A failure whose category is
/// a policy, exposure, tool, budget or human-decision refusal ends the failover. Continuing would use
/// the fallback chain to obtain work that policy declined to permit, which is the single most damaging
/// thing a fallback could do — and it would look, in the records, exactly like resilience.
/// </para>
/// <para>
/// <b>A provider whose egress permission changed ends the failover too.</b> The governance decision on
/// a candidate was evaluated against the destination class its provider implied. If that implication
/// has changed, the decision no longer describes this route, and executing under it would apply a
/// local-egress approval to remote egress. The route is refused and the failover stops, because the
/// same could be true of every other member of the chain.
/// </para>
/// </remarks>
public sealed class GovernedAiFailoverSelector : IAiFailoverSelector
{
    private readonly IAiOperationalEligibility _operations;
    private readonly IAiModelHealthSource _health;
    private readonly IAiModelRegistry _models;
    private readonly IAiProviderRegistry _providers;

    /// <summary>Builds the selector over the operational stage and the live registries.</summary>
    public GovernedAiFailoverSelector(
        IAiOperationalEligibility operations,
        IAiModelHealthSource health,
        IAiModelRegistry models,
        IAiProviderRegistry providers)
    {
        ArgumentNullException.ThrowIfNull(operations);
        ArgumentNullException.ThrowIfNull(health);
        ArgumentNullException.ThrowIfNull(models);
        ArgumentNullException.ThrowIfNull(providers);

        _operations = operations;
        _health = health;
        _models = models;
        _providers = providers;
    }

    /// <inheritdoc />
    public AiFailoverStep Next(
        AiCapabilityRequest request,
        AiRoutingContext routing,
        AiRoutingOutcome outcome,
        IReadOnlyList<AiFailoverAttempt> attempts,
        AiFailure? failure,
        DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(routing);
        ArgumentNullException.ThrowIfNull(outcome);

        // Tolerant of a null list as well as an empty one: a caller asking about the first failure has
        // no attempts to report yet, and making it construct an empty list to say so would be a tax on
        // the common case for no gain.
        attempts ??= [];

        // Nothing has failed, so there is nothing to fail over from. Reported as a decision rather than
        // as an absence, so that a caller which asked the question can record that it asked.
        if (failure is null)
        {
            return Stop(
                AiFailoverReasonCode.HealthyRoute,
                "No attempt has failed, so no alternate route is being sought.");
        }

        if (IsGovernanceRefusal(failure.Category))
        {
            return Stop(
                AiFailoverReasonCode.GovernanceBlockNotFailover,
                $"The execution was refused by governance with '{failure.Category}' ({failure.Code}). "
                + "A fallback route is not a way around a refusal: the chain is searched only for "
                + "operational failures, never to obtain work policy declined to permit.");
        }

        if (!failure.Retryable)
        {
            return Stop(
                AiFailoverReasonCode.FailureNotRetryable,
                $"The failure category '{failure.Category}' ({failure.Code}) is not retryable, so moving "
                + "to another route would repeat a request the estate already knows cannot succeed.");
        }

        if (outcome.FallbackChain.Count == 0)
        {
            return Stop(
                AiFailoverReasonCode.NoHealthyAlternate,
                $"No alternate route is configured for '{request.Capability}'. The estate's fallback "
                + "depth for this capability is zero, so a primary failure is an execution failure.");
        }

        var skipped = new List<AiFailoverAttempt>();

        for (var index = 0; index < outcome.FallbackChain.Count; index++)
        {
            var candidate = outcome.FallbackChain[index];

            // Order continues past the primary, so a chain member's position is its position in the
            // whole sequence rather than in the chain alone. Two records that both said "order 0" would
            // make the failover sequence unreconstructable.
            var order = index + 1;

            if (AlreadyAttempted(candidate, attempts))
            {
                skipped.Add(Reject(
                    candidate, order, AiFailoverReasonCode.AlternateFailed,
                    "This route has already been attempted in this execution and did not succeed.", at));
                continue;
            }

            Evaluate(request, routing, candidate, at, out var refreshed, out var refusal, out var admitted);

            if (refusal is not null)
            {
                skipped.Add(refusal with { Order = order });
                continue;
            }

            return new AiFailoverStep
            {
                Candidate = refreshed,
                Operational = admitted,
                ReasonCode = AiFailoverReasonCode.AttemptingAlternate,
                Detail = $"Attempting '{candidate.ModelId}' on provider '{candidate.ProviderId}' as "
                    + $"fallback step {order} of {outcome.FallbackChain.Count}. Governance permitted this "
                    + "route for this request when the chain was built, and it has been re-checked "
                    + "against live health and cost before being used.",
                Skipped = skipped,
            };
        }

        return new AiFailoverStep
        {
            ReasonCode = AiFailoverReasonCode.FallbackDepthExhausted,
            Detail = $"Every one of the {outcome.FallbackChain.Count} configured alternate route(s) was "
                + "refused on re-evaluation, so the execution fails rather than continuing to search.",
            Skipped = skipped,
        };
    }

    /// <summary>
    /// Re-reads the live gates for one chain member, refreshing the candidate or refusing it.
    /// </summary>
    /// <remarks>
    /// The gates run in the directive's order — registration, then health, then the operational stage's
    /// tier, reliability and budget — and the first one to refuse is the one reported. The operational
    /// stage reports all of its own findings, and this takes the first, because a failover step records
    /// one reason: a skipped candidate with five reasons attached is a record nobody reads.
    /// </remarks>
    private void Evaluate(
        AiCapabilityRequest request,
        AiRoutingContext routing,
        AiRoutingCandidate candidate,
        DateTimeOffset at,
        out AiRoutingCandidate? refreshed,
        out AiFailoverAttempt? refusal,
        out AiOperationalVerdict? admitted)
    {
        refreshed = null;
        refusal = null;
        admitted = null;

        if (!candidate.Governance.IsAllowed)
        {
            refusal = Reject(
                candidate, 0, AiFailoverReasonCode.GovernanceBlockNotFailover,
                "The candidate carries a governance decision that does not permit it. A chain member "
                + "without an allowing decision is a defect in the chain, not a route to use.", at,
                governance: candidate.Governance);
            return;
        }

        if (!_models.TryGetModel(candidate.ModelId, out var model) || model is null)
        {
            refusal = Reject(
                candidate, 0, AiFailoverReasonCode.AlternateRejectedByRouter,
                $"Model '{candidate.ModelId}' is no longer registered, so the route governance admitted "
                + "no longer exists.", at);
            return;
        }

        if (!_providers.TryGetProvider(candidate.ProviderId, out var provider) || provider is null)
        {
            refusal = Reject(
                candidate, 0, AiFailoverReasonCode.ProviderDisabled,
                $"Provider '{candidate.ProviderId}' is no longer registered.", at);
            return;
        }

        if (!provider.Enabled)
        {
            refusal = Reject(
                candidate, 0, AiFailoverReasonCode.ProviderDisabled,
                $"Provider '{candidate.ProviderId}' has been switched off since the chain was built.", at);
            return;
        }

        if (!model.Enabled || !model.Availability.IsRoutable())
        {
            refusal = Reject(
                candidate, 0, AiFailoverReasonCode.AlternateRejectedByRouter,
                $"Model '{candidate.ModelId}' is now {(model.Enabled ? $"at lifecycle state {model.Availability}" : "switched off")}, "
                + "which the router would refuse.", at);
            return;
        }

        // Egress permission is re-derived, and a change ends the failover. The governance decision on
        // this candidate was evaluated against the destination its provider implied at routing time;
        // if that implication has changed, proceeding would apply a local-egress approval to a remote
        // destination. The rotation is not attempted because the same provider registration is what
        // every other chain member's destination came from.
        if (provider.PermitsRemoteEgress != candidate.Provider.PermitsRemoteEgress)
        {
            refusal = Reject(
                candidate, 0, AiFailoverReasonCode.GovernanceBlockNotFailover,
                $"Provider '{candidate.ProviderId}' changed its remote-egress permission since governance "
                + $"evaluated this route, so the decision no longer describes destination "
                + $"'{candidate.Destination}'. Executing under it would apply an approval granted for a "
                + "different destination.", at, governance: candidate.Governance);
            return;
        }

        var modelHealth = _health.GetModelHealth(candidate.ModelId, candidate.ProviderId);
        var providerHealth = _health.GetProviderHealth(candidate.ProviderId);

        if (HealthRefusal(candidate, modelHealth, providerHealth, at) is { } healthRefusal)
        {
            refusal = healthRefusal;
            return;
        }

        var live = candidate with
        {
            Model = model,
            Provider = provider,
            ModelHealth = modelHealth,
            ProviderHealth = providerHealth,
        };

        var verdict = _operations.Evaluate(new AiOperationalContext
        {
            RequestId = request.RequestId,
            Capability = request.Capability,
            Candidate = live,
            Tier = routing.ProcessingTier,
            ProductId = request.Requester.ProductId,
            TenantId = request.Requester.TenantId,
            WorkspaceId = request.Requester.WorkspaceId,
            InputTokens = routing.InputTokens,
            OutputTokens = routing.OutputTokens,
            Now = at,
        });

        if (verdict.IsEligible)
        {
            refreshed = live;

            // The verdict that admitted this route travels with it. It is the exact counterpart of the
            // `budget:` and `reliability:` arguments on the refusal below, and it was the half that was
            // dropped: a member the selector refused had its evidence recorded, and a member it accepted
            // — the one that goes on to be called, and therefore the one that spends — had none. The one
            // line above already holds the whole verdict, so this is a carry rather than a computation.
            admitted = verdict;
            return;
        }

        var first = verdict.Rejections[0];

        refusal = Reject(
            candidate, 0, CodeFor(first.Reason, verdict), first.Detail, at,
            reliability: verdict.Reliability, budget: verdict.Budget);

        return;
    }

    /// <summary>
    /// Reads live health, distinguishing the reasons a route is unusable.
    /// </summary>
    /// <remarks>
    /// <see cref="AiModelHealthState.Unknown"/> and <see cref="AiModelHealthState.AuthError"/> get their
    /// own codes because their remedies differ from an outage: the first means nobody has observed the
    /// route, so calling it a fallback would be reaching for a route nobody has checked, and the second
    /// means a human has to act — a credential has to be rotated — which no amount of retrying reaches.
    /// </remarks>
    private static AiFailoverAttempt? HealthRefusal(
        AiRoutingCandidate candidate,
        AiModelHealthState modelHealth,
        AiModelHealthState providerHealth,
        DateTimeOffset at)
    {
        if (providerHealth is AiModelHealthState.AuthError || modelHealth is AiModelHealthState.AuthError)
        {
            return Reject(
                candidate, 0, AiFailoverReasonCode.AuthRequiresHuman,
                $"Provider '{candidate.ProviderId}' reports an authentication error. This route cannot be "
                + "retried and no alternate on this provider would help: a human has to restore the "
                + "credential before it can be used.", at);
        }

        if (modelHealth is AiModelHealthState.Unknown || providerHealth is AiModelHealthState.Unknown)
        {
            return Reject(
                candidate, 0, AiFailoverReasonCode.HealthUnknown,
                $"Health is unknown for '{candidate.ModelId}' ({modelHealth}) on provider "
                + $"'{candidate.ProviderId}' ({providerHealth}). Nothing has observed this route, and "
                + "falling back to a route nobody has checked is not a fallback.", at);
        }

        if (!modelHealth.IsRoutable() || !providerHealth.IsRoutable())
        {
            return Reject(
                candidate, 0, AiFailoverReasonCode.RouteUnhealthy,
                $"Health has fallen to model '{modelHealth}' / provider '{providerHealth}' for "
                + $"'{candidate.ModelId}' on '{candidate.ProviderId}' since the chain was built.", at);
        }

        return null;
    }

    /// <summary>
    /// Translates an operational refusal into the failover vocabulary.
    /// </summary>
    /// <remarks>
    /// A budget refusal that a human could override is reported as such rather than as a plain
    /// over-budget skip, because the two lead to different actions: one is a ceiling that will not
    /// move, the other is a decision waiting on a person.
    /// </remarks>
    private static AiFailoverReasonCode CodeFor(AiRoutingRejectionReason reason, AiOperationalVerdict verdict) => reason switch
    {
        AiRoutingRejectionReason.ProcessingTierUnsupported => AiFailoverReasonCode.AlternateTierUnsupported,
        AiRoutingRejectionReason.ReliabilityTooLow => AiFailoverReasonCode.AlternateReliabilityTooLow,
        AiRoutingRejectionReason.ReliabilityEvidenceMissing => AiFailoverReasonCode.AlternateReliabilityTooLow,

        // A fallback whose circuit is open is refused on the same axis as one refused for its rate, and
        // is reported the same way. The distinction between the two is on the operational verdict the
        // fallback attempt carries, which names the opening condition; collapsing the code here follows
        // the convention the two reliability members above already set, and inventing a third code would
        // make the fallback vocabulary say something the routing vocabulary already says better.
        AiRoutingRejectionReason.CircuitOpen => AiFailoverReasonCode.AlternateReliabilityTooLow,
        AiRoutingRejectionReason.BudgetExceeded when verdict.RequiresHumanDecision => AiFailoverReasonCode.BudgetRequiresOverride,
        AiRoutingRejectionReason.BudgetUncovered when verdict.RequiresHumanDecision => AiFailoverReasonCode.BudgetRequiresOverride,
        AiRoutingRejectionReason.BudgetExceeded => AiFailoverReasonCode.AlternateOverBudget,
        AiRoutingRejectionReason.BudgetUncovered => AiFailoverReasonCode.AlternateBudgetUnknown,
        _ => AiFailoverReasonCode.AlternateRejectedByRouter,
    };

    /// <summary>Builds a skipped-candidate record.</summary>
    private static AiFailoverAttempt Reject(
        AiRoutingCandidate candidate,
        int order,
        AiFailoverReasonCode code,
        string detail,
        DateTimeOffset at,
        AiGovernanceDecision? governance = null,
        AiReliabilityEvidence? reliability = null,
        AiBudgetDecision? budget = null) => new()
        {
            Order = order,
            ModelId = candidate.ModelId,
            ProviderId = candidate.ProviderId,
            Outcome = AiFailoverAttemptOutcome.Rejected,
            ReasonCode = code,
            Detail = detail,
            Governance = governance,
            Reliability = reliability,
            Budget = budget,
            At = at,
        };

    /// <summary>Builds a terminal step with no candidate.</summary>
    private static AiFailoverStep Stop(AiFailoverReasonCode code, string detail) => new()
    {
        ReasonCode = code,
        Detail = detail,
    };

    /// <summary>Whether this route already appears in the attempt list.</summary>
    /// <remarks>
    /// Matched on the model and provider together rather than on the model alone, because one model can
    /// be served by two providers and those are two different routes with two different outage modes.
    /// </remarks>
    private static bool AlreadyAttempted(AiRoutingCandidate candidate, IReadOnlyList<AiFailoverAttempt> attempts)
        => attempts.Any(attempt =>
            string.Equals(attempt.ModelId, candidate.ModelId, StringComparison.Ordinal)
            && string.Equals(attempt.ProviderId, candidate.ProviderId, StringComparison.Ordinal));

    /// <summary>
    /// Whether a failure category is a governance refusal rather than an operational one.
    /// </summary>
    /// <remarks>
    /// These are the categories that mean a decision was taken about whether the work may run at all.
    /// <see cref="AiFailureCategory.BudgetBlocked"/> is included even though budget is also W7E's: a
    /// route refused for cost must not be obtained through a cheaper fallback, or the ceiling would
    /// only bind the routes an operator happened to price highest.
    /// </remarks>
    private static bool IsGovernanceRefusal(AiFailureCategory category) => category switch
    {
        AiFailureCategory.PolicyBlocked => true,
        AiFailureCategory.DataExposureBlocked => true,
        AiFailureCategory.ToolPermissionDenied => true,
        AiFailureCategory.BudgetBlocked => true,
        AiFailureCategory.HumanDecisionRequired => true,
        _ => false,
    };
}
