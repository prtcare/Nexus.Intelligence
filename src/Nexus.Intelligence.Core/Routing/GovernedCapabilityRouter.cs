using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Routing;

/// <summary>
/// The routing path: a capability request in, a governed route or a typed refusal out.
/// </summary>
/// <remarks>
/// <para>
/// <b>The order of the stages is the security property, not an implementation detail.</b> Request-scope
/// governance runs before anything is looked up, per-candidate governance runs before anything is
/// ranked, and ranking runs only over candidates that governance has already permitted. A refactor
/// that moved governance after ranking would still refuse the routes it refuses — the set of permitted
/// candidates would be the same — but it would have ranked a route it was about to refuse, and the
/// first consequence would be a log line naming a model that must never be used. The order is
/// therefore asserted by tests rather than left to the reading of the method.
/// </para>
/// <para>
/// <b>Why governance runs twice.</b> The two passes answer different questions and neither subsumes
/// the other. The first asks whether <em>this request</em> may be served at all — a prohibited
/// capability, a tool the caller may not use, a declared escalation — and its answer does not depend
/// on which model is chosen, so routing around it is not possible. The second asks whether
/// <em>this route</em> may serve it — is this model approved, is this provider cleared for this
/// classification, is this provider's egress permitted — and its answer is exactly the one a different
/// model can change. Collapsing them into one pass over candidates would let a request-scoped refusal
/// be escaped by finding a route that does not trigger it, which is the directive's "fallback cannot
/// bypass governance" failing in the one place it is easiest to miss.
/// </para>
/// <para>
/// <b>A human decision is terminal, and a block is not.</b> A blocked <em>route</em> is excluded and
/// the search continues, because the refusal was about that model or provider and choosing a different
/// one is not a circumvention. A human-required decision stops the routing entirely: a person has been
/// asked to decide, and selecting a different model so that nobody has to is the silent downgrade that
/// W7B's escalation design exists to prevent. It would also be trivially reachable — every estate with
/// two models of differing cost has an escalation rule that one of them avoids.
/// </para>
/// <para>
/// <b>What this type cannot do.</b> It holds no credential, no client and no endpoint: its collaborators
/// are two read-only registries, a health source, the governance evaluator, the operational gate and a
/// policy, and its only output is a value of <see cref="AiRoutingOutcome"/>. Invoking the selected route
/// is a separate act performed by the governed-invocation seam, on a candidate this type has already had
/// approved.
/// </para>
/// <para>
/// <b>The operational stage runs after governance and before ranking, and it can only refuse.</b> It is
/// the directive's order — governance eligibility, capability eligibility, operational health and
/// reliability, budget and cost, then routing — and the order is load-bearing in one direction only:
/// moving the operational gates before governance would let a route be refused for budget before anyone
/// asked whether policy permitted it, and the refusal would name a model that must never be used.
/// </para>
/// </remarks>
public sealed class GovernedCapabilityRouter : IAiCapabilityRouter
{
    private readonly IAiModelRegistry _models;
    private readonly IAiProviderRegistry _providers;
    private readonly IAiModelHealthSource _health;
    private readonly IAiGovernanceEvaluator _governance;
    private readonly IAiOperationalEligibility _operations;
    private readonly AiRoutingPolicy _policy;
    private readonly TimeProvider _time;

    /// <summary>Composes a router from its inputs, its operational stage and its policy.</summary>
    /// <exception cref="InvalidOperationException">The policy is malformed.</exception>
    public GovernedCapabilityRouter(
        IAiModelRegistry models,
        IAiProviderRegistry providers,
        IAiModelHealthSource health,
        IAiGovernanceEvaluator governance,
        IAiOperationalEligibility operations,
        AiRoutingPolicy policy,
        TimeProvider time)
    {
        ArgumentNullException.ThrowIfNull(models);
        ArgumentNullException.ThrowIfNull(providers);
        ArgumentNullException.ThrowIfNull(health);
        ArgumentNullException.ThrowIfNull(governance);
        ArgumentNullException.ThrowIfNull(operations);
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(time);

        policy.Validate();

        _models = models;
        _providers = providers;
        _health = health;
        _governance = governance;
        _operations = operations;
        _policy = policy;
        _time = time;
    }

    /// <inheritdoc />
    public AiRoutingOutcome Route(
        AiCapabilityRequest request,
        AiPlatformGovernanceAttestation platform,
        AiRoutingContext context)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(platform);
        ArgumentNullException.ThrowIfNull(context);

        // ---- STAGE 1: request-scope governance, before anything is looked up ------------------------
        //
        // No model and no provider are named, so the engine evaluates only what is true of the request
        // itself. A refusal here is one no route can avoid, which is why it ends the routing.
        var requestDecision = _governance.Evaluate(
            BuildGovernanceRequest(request, context, modelId: null, providerId: null,
                destination: AiDestinationClass.Local, estimatedCost: null),
            platform);

        if (!requestDecision.IsAllowed)
        {
            return Refuse(request, requestDecision, [], []);
        }

        // ---- STAGE 2: capability mapping -----------------------------------------------------------
        //
        // After governance, deliberately. A capability that is prohibited and a capability that nobody
        // serves are both unroutable, but only one of them is a governance act, and reporting the
        // second for the first would hide a refusal behind a gap in an inventory.
        var registered = _models.ListForCapability(request.Capability);

        if (registered.Count == 0)
        {
            return RefuseFor(
                request,
                AiRoutingStatus.CapabilityNotFound,
                requestDecision,
                $"No registered model serves '{request.Capability}'.",
                AiFailureCategory.CapabilityNotFound,
                "routing.capability-not-found");
        }

        // ---- STAGE 3: per-candidate eligibility, health and governance -----------------------------
        var eligible = new List<AiRoutingCandidate>();
        var rejected = new List<AiRoutingRejection>();
        AiGovernanceDecision? blocked = null;
        AiGovernanceDecision? humanRequired = null;
        AiRoutingRejection? humanRejection = null;

        // Every operational finding across every candidate, eligible or not. Reported separately from
        // the rejection list because a route that passed a gate still produced a finding, and an
        // operator asking "on what evidence was this admitted" needs the ones that did not refuse.
        var operationalFindings = new List<AiOperationalRejection>();

        // An operational refusal a human could lift, kept apart from an outright one for the same
        // reason a governance escalation is: routing to a route the rule does not cover is a way of
        // not asking the person the rule was written to ask.
        AiOperationalVerdict? budgetEscalation = null;

        // Keyed by route identity rather than by the candidate record. Ranking returns copies, so a
        // dictionary keyed on the record would miss the selected candidate — and a lookup that missed
        // would report "no operational evidence" for exactly the route that was chosen.
        var operationalVerdicts = new Dictionary<(string ModelId, string ProviderId), AiOperationalVerdict?>();

        foreach (var model in registered)
        {
            var providerId = model.ProviderId;

            void Reject(AiRoutingRejectionReason reason, string detail,
                AiGovernanceDecision? governance = null)
                => rejected.Add(new AiRoutingRejection
                {
                    ModelId = model.ModelId,
                    ProviderId = providerId,
                    Reason = reason,
                    Detail = detail,
                    Governance = governance,
                });

            if (!_providers.TryGetProvider(providerId, out var provider) || provider is null)
            {
                Reject(AiRoutingRejectionReason.ProviderNotRegistered,
                    $"No provider is registered as '{providerId}', so where this route would send content "
                    + "is unknown.");
                continue;
            }

            if (!model.Enabled)
            {
                Reject(AiRoutingRejectionReason.ModelDisabled, "The model is registered and switched off.");
                continue;
            }

            if (!provider.Enabled)
            {
                Reject(AiRoutingRejectionReason.ProviderDisabled,
                    "The provider is registered and switched off.");
                continue;
            }

            if (!model.Availability.IsRoutable())
            {
                Reject(AiRoutingRejectionReason.ModelLifecycleNotRoutable,
                    $"The model's availability is {model.Availability}, which is not routable.");
                continue;
            }

            var modelHealth = _health.GetModelHealth(model.ModelId, providerId);
            if (!modelHealth.IsRoutable())
            {
                Reject(AiRoutingRejectionReason.ModelUnhealthy,
                    $"Health for '{model.ModelId}' is reported as {modelHealth}.");
                continue;
            }

            var providerHealth = _health.GetProviderHealth(providerId);
            if (!providerHealth.IsRoutable())
            {
                Reject(AiRoutingRejectionReason.ProviderUnhealthy,
                    $"Health for provider '{providerId}' is reported as {providerHealth}.");
                continue;
            }

            // Capability fit is checked on both, because a provider may not offer a capability at all
            // and a specific model may not implement it. Either alone is a refusal.
            if (!model.Declares(request.Capability))
            {
                Reject(AiRoutingRejectionReason.CapabilityNotDeclaredByModel,
                    $"The model does not declare '{request.Capability}'.");
                continue;
            }

            if (!provider.Declares(request.Capability))
            {
                Reject(AiRoutingRejectionReason.CapabilityNotDeclaredByProvider,
                    $"The provider does not declare '{request.Capability}'.");
                continue;
            }

            if (!FitsContext(model, context, out var fitReason, out var fitDetail))
            {
                Reject(fitReason, fitDetail);
                continue;
            }

            if (model.Reasoning < context.RequiredReasoning)
            {
                Reject(AiRoutingRejectionReason.ReasoningInsufficient,
                    $"The model reasons at {model.Reasoning} and the work requires "
                    + $"{context.RequiredReasoning}.");
                continue;
            }

            // The destination is derived from the provider, per candidate, so the exposure policy
            // evaluates each route against the place content would actually go. Deriving it once for
            // the request would evaluate a remote fallback as though it were local.
            var destination = provider.PermitsRemoteEgress
                ? AiDestinationClass.RemoteProvider
                : AiDestinationClass.Local;

            var estimatedCost = model.EstimateCost(context.InputTokens, context.OutputTokens);

            if (request.Execution.MaxCost is { } ceiling)
            {
                if (estimatedCost is not { } predicted)
                {
                    Reject(AiRoutingRejectionReason.CostUnknownAgainstCallerCeiling,
                        $"The caller set a ceiling of {ceiling} {request.Execution.CostCurrency} and this "
                        + "route's rates do not allow a prediction.");
                    continue;
                }

                if (!string.Equals(model.CostCurrency, request.Execution.CostCurrency,
                        StringComparison.OrdinalIgnoreCase))
                {
                    Reject(AiRoutingRejectionReason.CostUnknownAgainstCallerCeiling,
                        $"The route prices in '{model.CostCurrency}' and the caller's ceiling is in "
                        + $"'{request.Execution.CostCurrency}', so the two cannot be compared.");
                    continue;
                }

                if (predicted > ceiling)
                {
                    Reject(AiRoutingRejectionReason.CallerCostCeilingExceeded,
                        $"The route is predicted to cost {predicted} {model.CostCurrency} against a caller "
                        + $"ceiling of {ceiling}.");
                    continue;
                }
            }

            var decision = _governance.Evaluate(
                BuildGovernanceRequest(request, context, model.ModelId, provider.ProviderId, destination,
                    estimatedCost),
                platform);

            if (decision.IsBlocked)
            {
                // Kept and combined so the outcome can report every rule that refused a route, not just
                // the last one seen.
                blocked = blocked is null ? decision : blocked.Combine(decision);
                Reject(AiRoutingRejectionReason.GovernanceBlocked, decision.Reason, decision);
                continue;
            }

            if (decision.RequiresHumanDecision)
            {
                // Recorded for every route that raised one, so an operator sees the whole picture, and
                // the first kept separately as the reason the whole routing stopped.
                var rejection = new AiRoutingRejection
                {
                    ModelId = model.ModelId,
                    ProviderId = providerId,
                    Reason = AiRoutingRejectionReason.GovernanceHumanDecisionRequired,
                    Detail = decision.Reason,
                    Governance = decision,
                };

                rejected.Add(rejection);
                humanRequired ??= decision;
                humanRejection ??= rejection;
                continue;
            }

            var candidate = new AiRoutingCandidate
            {
                Model = model,
                Provider = provider,
                Destination = destination,
                ModelHealth = modelHealth,
                ProviderHealth = providerHealth,
                EstimatedCost = estimatedCost,
                CostCurrency = model.CostCurrency,
                Governance = decision,
                Score = 0m,
            };

            // ---- STAGE 3b: the operational gates ---------------------------------------------------
            //
            // After governance and before ranking, which is the directive's order. Governance has
            // already admitted this route; the operational stage asks whether it can be afforded and
            // whether it has been working. It can only refuse — it does not rank, select or reorder —
            // so a refusal here is reported with the gate that produced it and the route is excluded
            // exactly as a governance refusal would exclude it.
            //
            // It runs over the candidate rather than over the model, because the thing being judged is
            // the route: its declared tier support, its observed reliability and its projected cost
            // against a scoped ceiling.
            var operational = EvaluateOperationally(request, context, candidate);

            if (operational is not null)
            {
                foreach (var finding in operational.Rejections)
                {
                    operationalFindings.Add(finding);

                    rejected.Add(new AiRoutingRejection
                    {
                        ModelId = finding.ModelId,
                        ProviderId = finding.ProviderId,
                        Reason = finding.Reason,
                        Detail = finding.Detail,
                    });
                }

                if (!operational.IsEligible)
                {
                    // A refusal a human could lift is kept separately, for the same reason a governance
                    // escalation is: routing around a decision that is waiting on a person is how the
                    // person stops being asked.
                    if (operational.RequiresHumanDecision)
                    {
                        budgetEscalation ??= operational;
                    }

                    continue;
                }
            }

            eligible.Add(candidate);
            operationalVerdicts[(model.ModelId, provider.ProviderId)] = operational;
        }

        // A human has been asked to decide. Routing to a route that does not ask is not an answer to
        // that request, it is a way of not asking.
        if (humanRequired is not null)
        {
            var combined = requestDecision.Combine(humanRequired);

            return new AiRoutingOutcome
            {
                RequestId = request.RequestId,
                Capability = request.Capability,
                Status = AiRoutingStatus.HumanDecisionRequired,
                Governance = combined,
                Rejected = rejected,
                OperationalFindings = operationalFindings,
                Reason = humanRejection?.Detail ?? combined.Reason,
                Failure = combined.ToFailure(CorrelationOf(request)),
            };
        }

        // An operational rule that escalates is a decision waiting on a person, so it stops the routing
        // for the same reason a governance escalation does. It is checked after the governance
        // escalation because governance is the wider authority: where both fired, the decision a
        // reviewer resolves first is the one that governs the capability, not the one that governs the
        // spend, and reporting the second would send them to the cheaper question.
        if (budgetEscalation?.Budget is { } escalatedBudget)
        {
            var ruleId = escalatedBudget.RuleId ?? AiGovernanceRules.BudgetExceeded;
            var reason = escalatedBudget.Reason
                ?? $"The operational budget rule '{ruleId}' requires a human decision for this route.";

            var combined = requestDecision.Combine(
                AiGovernanceDecision.HumanDecisionRequired(ruleId, reason, ruleId));

            return new AiRoutingOutcome
            {
                RequestId = request.RequestId,
                Capability = request.Capability,
                Status = AiRoutingStatus.HumanDecisionRequired,
                Governance = combined,
                Rejected = rejected,
                OperationalFindings = operationalFindings,
                Reason = reason,
                Failure = combined.ToFailure(CorrelationOf(request)),
            };
        }

        if (eligible.Count == 0)
        {
            // If governance refused every route, the outcome says so rather than reporting an empty
            // inventory. "Nothing can serve this" and "policy refused all of this" have different
            // remedies, and an operator who cannot tell them apart will look in the wrong place.
            if (blocked is not null)
            {
                return Refuse(request, requestDecision.Combine(blocked), eligible, rejected,
                    operationalFindings);
            }

            var detail = rejected.Count == 0
                ? $"Models serve '{request.Capability}', but none survived eligibility, health and the "
                    + "operational gates."
                : $"Models serve '{request.Capability}', but none survived eligibility, health and the "
                    + $"operational gates. {rejected.Count} route(s) were refused; the first was refused "
                    + $"for {rejected[0].Reason}.";

            return RefuseFor(
                request,
                AiRoutingStatus.NoEligibleModel,
                requestDecision,
                detail,
                CategoryFor(rejected),
                "routing.no-eligible-model",
                rejected,
                operationalFindings);
        }

        // ---- STAGE 4: ranking, over permitted routes only -------------------------------------------
        var ranked = Rank(eligible, _policy.Objective);
        var selected = ranked[0];

        return new AiRoutingOutcome
        {
            RequestId = request.RequestId,
            Capability = request.Capability,
            Status = AiRoutingStatus.Routed,
            Selected = selected,
            Eligible = ranked,
            FallbackChain = ranked.Skip(1).Take(_policy.FallbackDepth).ToArray(),
            Rejected = rejected,
            OperationalFindings = operationalFindings,
            SelectedOperational = operationalVerdicts.GetValueOrDefault(
                (selected.Model.ModelId, selected.Provider.ProviderId)),
            Governance = requestDecision.Combine(selected.Governance),
        };
    }

    /// <summary>The failure category for a set of refusals that left nothing eligible.</summary>
    /// <remarks>
    /// The category follows what actually emptied the set. A route refused for cost is not a route that
    /// was unavailable, and reporting it as one would send an operator to inspect provider health for a
    /// ceiling they configured themselves — the remedy is a different person's decision, which is
    /// exactly what a failure category exists to route.
    /// </remarks>
    private static AiFailureCategory CategoryFor(IReadOnlyList<AiRoutingRejection> rejected) => rejected
        .Any(rejection => rejection.Reason is
            AiRoutingRejectionReason.BudgetExceeded or AiRoutingRejectionReason.BudgetUncovered)
        ? AiFailureCategory.BudgetBlocked
        : AiFailureCategory.ModelUnavailable;

    // --- Governance ---------------------------------------------------------------------------------

    /// <summary>
    /// Builds the governance question for one route, or for the request when no route is named yet.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The caller's request is transcribed and extended, never reinterpreted: classification, policy,
    /// tools and requester are passed through exactly as the caller stated them, and only the members
    /// the AI Head owns — the selection, the destination, the predicted cost and the tool identifiers
    /// the execution will actually use — are added. A router that softened a caller's classification
    /// before asking would be answering a question nobody asked.
    /// </para>
    /// <para>
    /// <b>There is no product or budget scope here, because the governance request has no field for
    /// one.</b> A scope the router accepted and could not transmit would be a scope it silently
    /// dropped, so neither this method nor <see cref="AiRoutingContext"/> carries one.
    /// </para>
    /// </remarks>
    private static AiGovernanceEvaluationRequest BuildGovernanceRequest(
        AiCapabilityRequest request,
        AiRoutingContext context,
        string? modelId,
        string? providerId,
        AiDestinationClass destination,
        decimal? estimatedCost) => new()
        {
            RequestId = request.RequestId,
            Capability = request.Capability,
            Requester = request.Requester,
            Classification = request.Classification,
            ContextClassifications = context.ContextClassifications,
            Destination = destination,
            Execution = request.Execution,
            Tools = request.Tools,
            RequestedToolIds = context.RequestedToolIds,
            ModelId = modelId,
            ProviderId = providerId,
            EstimatedCost = estimatedCost,
            CorrelationId = CorrelationOf(request),
            Purpose = request.Purpose,
        };

    /// <summary>The correlation key: the caller's, or the request's own when they gave none.</summary>
    private static string CorrelationOf(AiCapabilityRequest request)
        => string.IsNullOrWhiteSpace(request.CorrelationId) ? request.RequestId : request.CorrelationId;

    // --- Context fit --------------------------------------------------------------------------------

    private static bool FitsContext(
        AiModelRegistration model,
        AiRoutingContext context,
        out AiRoutingRejectionReason reason,
        out string detail)
    {
        // An unstated size cannot fail a limit. A route is not refused for exceeding a ceiling nobody
        // named, which is why the estimate is checked for being present before it is checked for
        // fitting.
        if (context.InputTokens > 0)
        {
            if (model.MaxContextTokens is not { } window)
            {
                reason = AiRoutingRejectionReason.ContextLimitUnknown;
                detail = $"The work sends {context.InputTokens} tokens and the model states no input "
                    + "limit, so no fit can be checked.";
                return false;
            }

            // The output reserve counts against the same window, because a model's context limit bounds
            // the whole exchange rather than its input alone.
            var required = context.InputTokens + context.OutputTokens;

            if (required > window)
            {
                reason = AiRoutingRejectionReason.ContextTooSmall;
                detail = $"The work needs {required} tokens ({context.InputTokens} in, "
                    + $"{context.OutputTokens} reserved out) against a window of {window}.";
                return false;
            }
        }

        if (context.OutputTokens > 0)
        {
            if (model.MaxOutputTokens is not { } maxOutput)
            {
                reason = AiRoutingRejectionReason.OutputLimitUnknown;
                detail = $"The work expects {context.OutputTokens} tokens back and the model states no "
                    + "output limit, so no fit can be checked.";
                return false;
            }

            if (context.OutputTokens > maxOutput)
            {
                reason = AiRoutingRejectionReason.OutputLimitExceedsModel;
                detail = $"The work expects {context.OutputTokens} tokens back against a model output "
                    + $"limit of {maxOutput}.";
                return false;
            }
        }

        if (!model.InputModalities.Contains(context.InputModality))
        {
            reason = AiRoutingRejectionReason.InputModalityUnsupported;
            detail = $"The model does not accept {context.InputModality} input.";
            return false;
        }

        if (!model.OutputModalities.Contains(context.OutputModality))
        {
            reason = AiRoutingRejectionReason.OutputModalityUnsupported;
            detail = $"The model does not produce {context.OutputModality} output.";
            return false;
        }

        reason = default;
        detail = string.Empty;
        return true;
    }

    // --- Ranking ------------------------------------------------------------------------------------

    /// <summary>
    /// Scores and orders permitted routes. Deterministic for a given set and objective.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Cost and priority are normalised against the set, because both are open-ended scalars whose
    /// absolute values mean nothing on their own — a route costing 4 is expensive or cheap depending
    /// on what else is available, and a priority of 50 is high or low depending on the range in use.
    /// Health, trust, reasoning and speed need no normalisation: they are already closed scales.
    /// </para>
    /// <para>
    /// <b>The tie-breakers are written down.</b> Score, then the operator's priority, then model
    /// identifier, then provider identifier, all ordinal. Without the last two, two routes with equal
    /// scores would be ordered by whatever order the registry happened to return, and the estate's
    /// routing would be a property of a dictionary's internals.
    /// </para>
    /// </remarks>
    private static IReadOnlyList<AiRoutingCandidate> Rank(
        IReadOnlyList<AiRoutingCandidate> eligible,
        AiRoutingObjective objective)
    {
        var weights = AiRoutingWeights.For(objective);
        var maxCost = eligible.Max(c => c.EstimatedCost ?? 0m);
        var minPriority = eligible.Min(c => c.Provider.Priority);
        var maxPriority = eligible.Max(c => c.Provider.Priority);
        var prioritySpan = maxPriority - minPriority;

        return eligible
            .Select(candidate =>
            {
                var cost = candidate.EstimatedCost;
                var costScore = cost is null
                    ? 0.0
                    : maxCost <= 0m
                        ? 1.0
                        : Math.Max(0.0, 1.0 - (double)(cost.Value / maxCost));

                var reliability = candidate.Provider.Trust.Score();

                // The narrower of the two health readings: a healthy model behind an unhealthy provider
                // is not a healthy route.
                var health = Math.Min(candidate.ModelHealth.Score(), candidate.ProviderHealth.Score());
                var reasoning = candidate.Model.Reasoning.Score();
                var speed = candidate.Model.RelativeSpeed.Score();

                var priority = prioritySpan == 0
                    ? 0.5
                    : (double)(candidate.Provider.Priority - minPriority) / prioritySpan;

                var weighted =
                    (weights.Cost * costScore)
                    + (weights.Reliability * reliability)
                    + (weights.Reasoning * reasoning)
                    + (weights.Health * health)
                    + (weights.Priority * priority)
                    + (weights.Speed * speed);

                var score = decimal.Round((decimal)(weighted * candidate.Provider.Weight), 6);

                return candidate with
                {
                    Score = score,
                    ScoreComponents =
                    [
                        $"objective={objective}",
                        $"cost={costScore:F3}",
                        $"reliability={reliability:F3}",
                        $"reasoning={reasoning:F3}",
                        $"health={health:F3}",
                        $"priority={priority:F3}",
                        $"speed={speed:F3}",
                        $"weight={candidate.Provider.Weight:F2}",
                        $"score={score}",
                    ],
                };
            })
            .OrderByDescending(c => c.Score)
            .ThenByDescending(c => c.Provider.Priority)
            .ThenBy(c => c.Model.ModelId, StringComparer.Ordinal)
            .ThenBy(c => c.Provider.ProviderId, StringComparer.Ordinal)
            .ToArray();
    }

    // --- Refusals -----------------------------------------------------------------------------------

    /// <summary>
    /// A refusal whose cause is governance.
    /// </summary>
    /// <remarks>
    /// The status follows the verdict rather than being fixed, because a request awaiting a human is
    /// not a request that policy blocked, and a caller that could not tell them apart would retry the
    /// first and escalate the second.
    /// </remarks>
    private static AiRoutingOutcome Refuse(
        AiCapabilityRequest request,
        AiGovernanceDecision decision,
        IReadOnlyList<AiRoutingCandidate> eligible,
        IReadOnlyList<AiRoutingRejection> rejected,
        IReadOnlyList<AiOperationalRejection>? operationalFindings = null) => new()
        {
            RequestId = request.RequestId,
            Capability = request.Capability,
            Status = decision.RequiresHumanDecision
                ? AiRoutingStatus.HumanDecisionRequired
                : AiRoutingStatus.GovernanceBlocked,
            Eligible = eligible,
            Rejected = rejected,
            OperationalFindings = operationalFindings ?? [],
            Governance = decision,
            Reason = decision.Reason,
            Failure = decision.ToFailure(CorrelationOf(request)),
        };

    /// <summary>A refusal whose cause is not governance: no such capability, or nothing eligible.</summary>
    /// <remarks>
    /// Every path through this method is reached before or without the operational stage, except the
    /// no-eligible-route path, which passes its findings in. The parameter is optional because a refusal
    /// that never ran the stage has no findings — a different fact from a stage that ran and found
    /// nothing, which is why it is null-defaulted rather than always passed an empty list.
    /// </remarks>
    private static AiRoutingOutcome RefuseFor(
        AiCapabilityRequest request,
        AiRoutingStatus status,
        AiGovernanceDecision governance,
        string detail,
        AiFailureCategory category,
        string code,
        IReadOnlyList<AiRoutingRejection>? rejected = null,
        IReadOnlyList<AiOperationalRejection>? operationalFindings = null)
    {
        var failure = AiFailure.From(category, code, detail, CorrelationOf(request));

        return new AiRoutingOutcome
        {
            RequestId = request.RequestId,
            Capability = request.Capability,
            Status = status,
            Governance = governance,
            Rejected = rejected ?? [],
            OperationalFindings = operationalFindings ?? [],
            Reason = failure.Message,
            Failure = failure,
        };
    }

    // --- The operational stage ----------------------------------------------------------------------

    /// <summary>
    /// Runs the operational gates over one governance-permitted route.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>It re-reads nothing and probes nothing.</b> Everything the gates consult — the health
    /// snapshot, the reliability history, the cost ledger and the pricing metadata — is read
    /// synchronously from an in-process record, and the clock is the one the router was composed with.
    /// A probe here would make routing's output depend on a network round trip, and the reproducibility
    /// the routing contract claims would be a claim about a machine rather than about the decision.
    /// </para>
    /// <para>
    /// <b>The tier comes from the routing context, not from the model.</b> It is the tier the work was
    /// dispatched under, which is what the gate is asked to judge; the model's declared support is the
    /// other side of that comparison and is read from the candidate.
    /// </para>
    /// </remarks>
    private AiOperationalVerdict EvaluateOperationally(
        AiCapabilityRequest request,
        AiRoutingContext context,
        AiRoutingCandidate candidate) => _operations.Evaluate(new AiOperationalContext
        {
            RequestId = request.RequestId,
            Capability = request.Capability,
            Candidate = candidate,
            Tier = context.ProcessingTier,
            ProductId = request.Requester.ProductId,
            TenantId = request.Requester.TenantId,
            WorkspaceId = request.Requester.WorkspaceId,
            InputTokens = context.InputTokens,
            OutputTokens = context.OutputTokens,
            Now = _time.GetUtcNow(),
        });
}
