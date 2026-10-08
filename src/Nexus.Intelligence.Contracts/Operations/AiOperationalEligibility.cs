namespace Nexus.Intelligence.Contracts;

/// <summary>
/// Everything the operational stage is asked to judge about one candidate route.
/// </summary>
/// <remarks>
/// <para>
/// <b>It carries a candidate that governance has already permitted.</b> This stage runs after the
/// per-candidate governance evaluation, so a route arriving here is one policy has admitted. That
/// ordering is the directive's and it is load-bearing: an operational stage that ran first could
/// refuse a route for a reason no rule recorded, and a route refused for budget would be
/// indistinguishable from one refused for policy.
/// </para>
/// <para>
/// Nothing here is caller-supplied as a preference. The capability, the route and the projected cost
/// are all facts the AI Head derived; the identity fields come from the requester the caller named
/// and are used for attribution and scoping, never for selection.
/// </para>
/// </remarks>
public sealed record AiOperationalContext
{
    /// <summary>The caller's request identifier, for correlation.</summary>
    public required string RequestId { get; init; }

    /// <summary>The capability about to run.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>The route being evaluated.</summary>
    public required AiRoutingCandidate Candidate { get; init; }

    /// <summary>The processing tier the work is to run under.</summary>
    public AiProcessingTier Tier { get; init; } = AiProcessingTier.Standard;

    /// <summary>The product the spend would be attributed to.</summary>
    public string? ProductId { get; init; }

    /// <summary>The tenant the spend would be attributed to.</summary>
    public string? TenantId { get; init; }

    /// <summary>The workspace the spend would be attributed to.</summary>
    public string? WorkspaceId { get; init; }

    /// <summary>The token counts the route was costed with, so the estimate can be recomputed.</summary>
    public int InputTokens { get; init; }

    /// <summary>The output token count the route was costed with.</summary>
    public int OutputTokens { get; init; }

    /// <summary>When the evaluation is happening, for window selection.</summary>
    public required DateTimeOffset Now { get; init; }
}

/// <summary>One operational gate that refused a candidate, with the evidence behind it.</summary>
public sealed record AiOperationalRejection
{
    /// <summary>The model the gate refused.</summary>
    public required string ModelId { get; init; }

    /// <summary>The provider the gate refused.</summary>
    public required string ProviderId { get; init; }

    /// <summary>Which gate refused it.</summary>
    public required AiRoutingRejectionReason Reason { get; init; }

    /// <summary>The values behind the refusal — which threshold, by how much.</summary>
    public required string Detail { get; init; }

    /// <summary>The budget verdict, when the budget gate was the one that fired.</summary>
    public AiBudgetDecision? Budget { get; init; }

    /// <summary>The reliability evidence, when the reliability gate was the one that fired.</summary>
    public AiReliabilityEvidence? Reliability { get; init; }

    /// <summary>The circuit state, when the recovery model refused the route.</summary>
    /// <remarks>
    /// Carried on the refusal rather than only on the verdict so that the reason a route was refused
    /// and the facts that would change it travel together. A rejection that said "circuit open" and
    /// nothing else would leave a reader unable to tell a route that will be probed in a minute from
    /// one that will never be used again — which is the distinction the whole model exists to make.
    /// </remarks>
    public AiCircuitSnapshot? Circuit { get; init; }
}

/// <summary>What the operational stage concluded about one candidate.</summary>
public sealed record AiOperationalVerdict
{
    /// <summary>True when the candidate passes every operational gate.</summary>
    public required bool IsEligible { get; init; }

    /// <summary>Every gate that refused, in evaluation order. Empty when eligible.</summary>
    public IReadOnlyList<AiOperationalRejection> Rejections { get; init; } = [];

    /// <summary>The budget verdict, present when the budget gate ran and produced one.</summary>
    public AiBudgetDecision? Budget { get; init; }

    /// <summary>The reliability evidence the gate read, present when the gate ran.</summary>
    public AiReliabilityEvidence? Reliability { get; init; }

    /// <summary>The price quote the projected cost came from, where one was found.</summary>
    public string? PriceQuoteId { get; init; }

    /// <summary>The circuit state the recovery gate read, present when the model is applied.</summary>
    public AiCircuitSnapshot? Circuit { get; init; }

    /// <summary>
    /// True when this route was admitted only as a probationary probe rather than as ordinary traffic.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Set only where a route is in <see cref="AiCircuitState.HalfOpen"/> or
    /// <see cref="AiCircuitState.Recovering"/> and had probe allowance left.</b> It is the estate
    /// stating that this call is not work the route has earned back yet, which is what makes the
    /// bounded probe traffic bounded: the allowance is spent by calls that are labelled, counted and
    /// afterwards checked against what the provider actually did.
    /// </para>
    /// <para>
    /// <b>A probe is an ordinary governed execution.</b> Nothing about being a probe exempts the call
    /// from governance, from budget, from tier or from data policy — those gates run in this same
    /// stage and their refusals are reported alongside this flag rather than being overridden by it.
    /// A probationary route does not get a cheaper class of permission; it gets a smaller number of
    /// calls, on the same terms.
    /// </para>
    /// </remarks>
    public bool IsProbe { get; init; }

    /// <summary>True when any rejection escalates to a human rather than refusing outright.</summary>
    public bool RequiresHumanDecision => Rejections.Any(r => r.Budget?.RequiresHumanDecision is true);

    /// <summary>The first refusal's reason, for the router's rejection record.</summary>
    public AiRoutingRejectionReason? FirstReason => Rejections.Count == 0 ? null : Rejections[0].Reason;

    /// <summary>An eligible verdict, with the evidence that was gathered on the way.</summary>
    public static AiOperationalVerdict Eligible(
        AiBudgetDecision? budget,
        AiReliabilityEvidence? reliability,
        string? priceQuoteId,
        AiCircuitSnapshot? circuit = null,
        bool isProbe = false) => new()
        {
            IsEligible = true,
            Budget = budget,
            Reliability = reliability,
            PriceQuoteId = priceQuoteId,
            Circuit = circuit,
            IsProbe = isProbe,
        };
}

/// <summary>
/// The operational stage of the governed routing decision: health, reliability, recovery, budget and
/// tier.
/// </summary>
/// <remarks>
/// <para>
/// <b>One seam rather than five dependencies on the router.</b> The gates share one evaluation
/// context, one ordering and one verdict record; separately injected ports would let a future edit
/// reorder them without anything recording that the order changed, and the ordering is the
/// directive's requirement.
/// </para>
/// <para>
/// <b>Synchronous, pure and network-free.</b> It reads a health snapshot, an in-process reliability
/// history, an in-process cost ledger and registry pricing metadata. It performs no I/O and reaches
/// no provider, so routing remains the reproducible function its contract claims. That is also why
/// the recovery model is expressed as a derivation over recorded attempts rather than as a probe: a
/// gate that could ask a provider how it was would be a gate whose answer depended on the network.
/// </para>
/// <para>
/// <b>It can only refuse.</b> It never selects, ranks or reorders. Ranking belongs to the routing
/// policy, where an operator can set weights; a stage that both gated and ranked would make a
/// refusal's reason depend on the ranking it was competing in.
/// </para>
/// <para>
/// <b>Governance runs before this stage, and nothing here can undo it.</b>
/// <see cref="AiOperationalContext"/> carries a candidate governance has already permitted, so a
/// governance refusal never reaches these gates and cannot be reported as a recovery decision. The
/// consequence for the recovery model is deliberate: a cooldown can release a route the estate
/// stopped trusting, and can never release a route policy has blocked, because a blocked route is
/// never offered here to be released.
/// </para>
/// <para>
/// <b>The candidate is admitted as a whole.</b> A route in probation is admitted for a bounded number
/// of <em>ordinary</em> governed calls, fully subject to every other gate, rather than through a
/// privileged path. There is no caller-supplied input anywhere in this contract that can set, clear
/// or shorten a circuit, which is what makes it impossible for a product to put a route back into
/// service by asking.
/// </para>
/// </remarks>
public interface IAiOperationalEligibility
{
    /// <summary>Evaluates one candidate against the operational gates.</summary>
    AiOperationalVerdict Evaluate(AiOperationalContext context);
}
