using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// The operational stage: processing tier, observed reliability, circuit recovery, then budget and
/// cost.
/// </summary>
/// <remarks>
/// <para>
/// <b>The order is the directive's and it is fixed here rather than left to the caller.</b>
/// Governance eligibility, then capability eligibility, then operational health and reliability, then
/// budget and cost, then routing. Within this stage that means:
/// </para>
/// <list type="number">
/// <item>
/// <b>Processing tier</b> — a capability question. Whether a model can be run in the mode the work
/// needs is a statement about what the model is, and it is declared metadata rather than inferred
/// from a name.
/// </item>
/// <item>
/// <b>Reliability</b> — an operational question, answered from observed attempts and configured
/// thresholds.
/// </item>
/// <item>
/// <b>Circuit recovery</b> — whether the route is currently in service, in probation, or stopped, and
/// therefore whether this call may be spent on it at all. It reads the same observed attempts as the
/// gate above, because the question "is this route good enough" and the question "has the estate
/// decided to stop asking" are two questions about one history.
/// </item>
/// <item>
/// <b>Budget and cost</b> — last, because it is the only gate that needs a projected figure, and the
/// projection is only meaningful for a route that has already passed the gates above. It runs for a
/// probationary probe exactly as it runs for ordinary traffic; a probe is not free.
/// </item>
/// </list>
/// <para>
/// <b>Every gate runs, and every refusal is reported.</b> The gates do not short-circuit, so a route
/// that is both over budget and below its reliability floor reports both. A caller that fixed one
/// would otherwise resubmit and be refused again for the other, with the second refusal looking like
/// a new problem.
/// </para>
/// <para>
/// <b>It cannot reach a provider and cannot change a route.</b> No network, no mutation, no ranking.
/// The same context against the same snapshot, history and policy produces the same verdict, which is
/// what lets the router's determinism claim survive this stage being added to it.
/// </para>
/// </remarks>
public sealed class GovernedAiOperationalEligibility : IAiOperationalEligibility
{
    private readonly IAiPriceCatalogue _prices;
    private readonly IAiBudgetEvaluator _budget;
    private readonly IAiReliabilityHistory _reliability;
    private readonly AiReliabilityPolicy _reliabilityPolicy;
    private readonly IAiCircuitBreaker _circuit;
    private readonly AiCircuitPolicy _circuitPolicy;

    /// <summary>Builds the operational stage from its collaborators.</summary>
    public GovernedAiOperationalEligibility(
        IAiPriceCatalogue prices,
        IAiBudgetEvaluator budget,
        IAiReliabilityHistory reliability,
        AiReliabilityPolicy reliabilityPolicy,
        IAiCircuitBreaker circuit,
        AiCircuitPolicy circuitPolicy)
    {
        ArgumentNullException.ThrowIfNull(prices);
        ArgumentNullException.ThrowIfNull(budget);
        ArgumentNullException.ThrowIfNull(reliability);
        ArgumentNullException.ThrowIfNull(reliabilityPolicy);
        ArgumentNullException.ThrowIfNull(circuit);
        ArgumentNullException.ThrowIfNull(circuitPolicy);

        reliabilityPolicy.Validate();
        circuitPolicy.Validate();

        _prices = prices;
        _budget = budget;
        _reliability = reliability;
        _reliabilityPolicy = reliabilityPolicy;
        _circuit = circuit;
        _circuitPolicy = circuitPolicy;
    }

    /// <inheritdoc />
    public AiOperationalVerdict Evaluate(AiOperationalContext context)
    {
        ArgumentNullException.ThrowIfNull(context);

        var modelId = context.Candidate.ModelId;
        var providerId = context.Candidate.ProviderId;

        var rejections = new List<AiOperationalRejection>();

        EvaluateTier(context, rejections);
        var evidence = EvaluateReliability(context, modelId, providerId, rejections);
        var circuit = EvaluateCircuit(context, modelId, providerId, evidence, rejections);
        var (budget, priceQuoteId) = EvaluateCost(context, modelId, providerId, rejections);

        var isProbe = circuit?.IsProbePermitted is true;

        return rejections.Count == 0
            ? AiOperationalVerdict.Eligible(budget, evidence, priceQuoteId, circuit, isProbe)
            : new AiOperationalVerdict
            {
                IsEligible = false,
                Rejections = rejections,
                Budget = budget,
                Reliability = evidence,
                PriceQuoteId = priceQuoteId,
                Circuit = circuit,
                IsProbe = false,
            };
    }

    /// <summary>
    /// Whether the model declares support for the tier the work requires.
    /// </summary>
    /// <remarks>
    /// The declaration is the only source. A gate that inferred batch support from a model identifier
    /// or a provider name would classify the next model by resemblance to the last one, and the
    /// mis-classification would be silent because the gate would still return a definite answer.
    /// </remarks>
    private static void EvaluateTier(AiOperationalContext context, List<AiOperationalRejection> rejections)
    {
        if (context.Candidate.Model.SupportsTier(context.Tier))
        {
            return;
        }

        var declared = context.Candidate.Model.ProcessingTiers.Count == 0
            ? "none"
            : string.Join(", ", context.Candidate.Model.ProcessingTiers);

        rejections.Add(new AiOperationalRejection
        {
            ModelId = context.Candidate.ModelId,
            ProviderId = context.Candidate.ProviderId,
            Reason = AiRoutingRejectionReason.ProcessingTierUnsupported,
            Detail = $"Model '{context.Candidate.ModelId}' does not declare support for processing tier "
                + $"'{context.Tier}'. Its declared tiers are: {declared}. Support is read from the "
                + "registration's declared metadata and from nothing else.",
        });
    }

    /// <summary>
    /// Whether observed reliability clears the configured floors.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <see cref="AiRoutingRejectionReason.ReliabilityEvidenceMissing"/> and
    /// <see cref="AiRoutingRejectionReason.ReliabilityTooLow"/> are deliberately different outcomes.
    /// The first means the policy demands evidence and there is none; the second means there is
    /// enough evidence and it is bad. Their remedies differ — one is to let the route run and
    /// accumulate history, the other is to look at a provider — and collapsing them would make the
    /// estate's newest capacity look like its worst.
    /// </para>
    /// <para>
    /// The consecutive-failure ceiling is checked before the rate, because it is a current signal. A
    /// route that has just failed three times in a row is better described by that than by a rate
    /// diluted over a week of earlier successes.
    /// </para>
    /// </remarks>
    private AiReliabilityEvidence? EvaluateReliability(
        AiOperationalContext context,
        string modelId,
        string providerId,
        List<AiOperationalRejection> rejections)
    {
        if (!_reliabilityPolicy.Enabled)
        {
            return null;
        }

        var evidence = _reliability.EvidenceFor(providerId, modelId);

        if (evidence.Attempts == 0)
        {
            if (_reliabilityPolicy.RequireEvidence)
            {
                rejections.Add(new AiOperationalRejection
                {
                    ModelId = modelId,
                    ProviderId = providerId,
                    Reason = AiRoutingRejectionReason.ReliabilityEvidenceMissing,
                    Detail = $"The configured reliability policy requires evidence before a route may be "
                        + $"used, and no attempt has been observed for model '{modelId}' on provider "
                        + $"'{providerId}'.",
                    Reliability = evidence,
                });
            }

            return evidence;
        }

        // The ceiling and the rate are the conditions that open a circuit. Where the recovery model is
        // applied they are the circuit gate's to act on, and this gate reports the evidence without
        // also refusing: two refusals for one condition would mean a route whose circuit had recovered
        // was still refused by the measurement that opened it, which is the latch the model exists to
        // remove. Where the recovery model is not applied these branches run exactly as they always
        // did, and a route refused here stays refused — the stated, supported posture of an estate
        // that has not configured a cooldown.
        if (_circuitPolicy.Enabled)
        {
            return evidence;
        }

        if (evidence.ConsecutiveFailures >= _reliabilityPolicy.ConsecutiveFailureCeiling)
        {
            rejections.Add(new AiOperationalRejection
            {
                ModelId = modelId,
                ProviderId = providerId,
                Reason = AiRoutingRejectionReason.ReliabilityTooLow,
                Detail = $"Model '{modelId}' on provider '{providerId}' has failed "
                    + $"{evidence.ConsecutiveFailures} consecutive attempt(s), at or above the configured "
                    + $"ceiling of {_reliabilityPolicy.ConsecutiveFailureCeiling}. Most recent failure: "
                    + $"{evidence.LastFailureCategory?.ToString() ?? "unspecified"}.",
                Reliability = evidence,
            });

            return evidence;
        }

        if (evidence.Attempts >= _reliabilityPolicy.MinimumSampleSize
            && evidence.SuccessRate is { } rate
            && rate < _reliabilityPolicy.MinimumSuccessRate)
        {
            rejections.Add(new AiOperationalRejection
            {
                ModelId = modelId,
                ProviderId = providerId,
                Reason = AiRoutingRejectionReason.ReliabilityTooLow,
                Detail = $"Model '{modelId}' on provider '{providerId}' has an observed success rate of "
                    + $"{rate:F4} over {evidence.Attempts} attempt(s), below the configured floor of "
                    + $"{_reliabilityPolicy.MinimumSuccessRate:F4} on a minimum sample of "
                    + $"{_reliabilityPolicy.MinimumSampleSize}.",
                Reliability = evidence,
            });
        }

        return evidence;
    }

    /// <summary>
    /// Whether the route's circuit permits this call, and on what terms.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>A route is in exactly one of three postures, and the gate says which.</b> Eligible — its
    /// circuit is healthy or degraded and it is treated as ordinary capacity. Probationary —
    /// <see cref="AiCircuitState.HalfOpen"/> or <see cref="AiCircuitState.Recovering"/> with allowance
    /// left, so the call is admitted and flagged as a probe. Refused — its circuit is open, so the
    /// call does not run.
    /// </para>
    /// <para>
    /// <b>Probation does not relax anything.</b> The admitted probe runs the remaining gates in this
    /// same stage, so a route being retested still has to clear its tier and its budget, and is refused
    /// if it does not. Being under probation is a statement about how many calls the estate is willing
    /// to spend, not about which rules apply to them.
    /// </para>
    /// <para>
    /// <b>Nothing on the context can influence a circuit.</b> The gate reads a snapshot derived from
    /// recorded attempts and the configured policy. Capability, requester, price ceiling and token
    /// counts are on the context and none of them is a circuit input, so no product, tenant or caller
    /// can open, close or shorten one by asking.
    /// </para>
    /// <para>
    /// <b>The refusal carries both halves of its cause.</b> A circuit opens <em>on</em> the observed
    /// record, so the refusal states the record as well as the state it produced. They are read from
    /// one history at one instant two lines apart in this method, so they cannot disagree; carrying
    /// only the circuit would leave the operator to reconstruct the measurement the estate actually
    /// acted on, and that reconstruction is where an operator concludes the wrong threshold fired.
    /// </para>
    /// </remarks>
    private AiCircuitSnapshot? EvaluateCircuit(
        AiOperationalContext context,
        string modelId,
        string providerId,
        AiReliabilityEvidence? evidence,
        List<AiOperationalRejection> rejections)
    {
        if (!_circuitPolicy.Enabled)
        {
            return null;
        }

        var snapshot = _circuit.For(providerId, modelId, context.Now);

        if (snapshot.IsEligible || snapshot.IsProbePermitted)
        {
            return snapshot;
        }

        rejections.Add(new AiOperationalRejection
        {
            ModelId = modelId,
            ProviderId = providerId,
            Reason = AiRoutingRejectionReason.CircuitOpen,
            Detail = snapshot.Detail,
            Reliability = evidence,
            Circuit = snapshot,
        });

        return snapshot;
    }

    /// <summary>
    /// Whether the route is within the estate's operational budget.
    /// </summary>
    /// <remarks>
    /// The projection is taken from the price catalogue first and from the candidate second, because
    /// the catalogue is the authority on price and the candidate's figure is the router's own
    /// arithmetic over the same metadata. Where neither yields a figure the budget gate has nothing
    /// to compare and says so through its policy — it does not invent a number, and it does not read
    /// silence as unlimited.
    /// </remarks>
    private (AiBudgetDecision? Budget, string? PriceQuoteId) EvaluateCost(
        AiOperationalContext context,
        string modelId,
        string providerId,
        List<AiOperationalRejection> rejections)
    {
        var lookup = _prices.Lookup(modelId, providerId, context.Tier);

        var projected = lookup.Quote?.CostOf(context.InputTokens, context.OutputTokens)
            ?? context.Candidate.EstimatedCost;

        var currency = lookup.Quote?.Currency ?? context.Candidate.CostCurrency;

        var decision = _budget.Evaluate(new AiBudgetContext
        {
            Capability = context.Capability,
            ProductId = context.ProductId,
            TenantId = context.TenantId,
            WorkspaceId = context.WorkspaceId,
            ProviderId = providerId,
            ModelId = modelId,
            ProjectedCost = projected,
            Currency = currency,
            Now = context.Now,
        });

        if (decision.IsAllowed)
        {
            return (decision, lookup.Quote?.QuoteId);
        }

        rejections.Add(new AiOperationalRejection
        {
            ModelId = modelId,
            ProviderId = providerId,
            Reason = decision.CommittedSpend is null && decision.RuleId is null
                ? AiRoutingRejectionReason.BudgetUncovered
                : AiRoutingRejectionReason.BudgetExceeded,
            Detail = decision.Reason ?? "The operational budget gate refused this route without a reason.",
            Budget = decision,
        });

        return (decision, lookup.Quote?.QuoteId);
    }
}
