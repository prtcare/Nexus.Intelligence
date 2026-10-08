namespace Nexus.Intelligence.Contracts;

/// <summary>
/// What happened at one step of a failover, with the code an operator reads.
/// </summary>
/// <remarks>
/// <para>
/// <b>Every candidate the failover considered is recorded, whether or not it was used.</b> A failover
/// that reported only its final choice would leave "why did it not try the one I expected"
/// unanswerable, which is the same defect the router's rejection list exists to prevent.
/// </para>
/// <para>
/// <see cref="Governance"/> is carried when governance was the gate, so a refusal that came from
/// policy is reported as the policy's own decision rather than restated in the failover's words.
/// </para>
/// </remarks>
public sealed record AiFailoverAttempt
{
    /// <summary>Position in the failover order. Zero is the primary route.</summary>
    public required int Order { get; init; }

    /// <summary>The model this step would use.</summary>
    public required string ModelId { get; init; }

    /// <summary>The provider this step would use.</summary>
    public required string ProviderId { get; init; }

    /// <summary>Which stage decided about this step.</summary>
    public required AiFailoverAttemptOutcome Outcome { get; init; }

    /// <summary>Why, in the estate's existing failover vocabulary.</summary>
    public required AiFailoverReasonCode ReasonCode { get; init; }

    /// <summary>The values behind the decision — which threshold, by how much.</summary>
    public required string Detail { get; init; }

    /// <summary>The governance decision, when governance was the gate that decided.</summary>
    public AiGovernanceDecision? Governance { get; init; }

    /// <summary>The reliability evidence at the moment of the decision, where it was read.</summary>
    public AiReliabilityEvidence? Reliability { get; init; }

    /// <summary>The budget verdict at the moment of the decision, where it was read.</summary>
    public AiBudgetDecision? Budget { get; init; }

    /// <summary>When this step was decided.</summary>
    public required DateTimeOffset At { get; init; }
}

/// <summary>What the failover concluded about one candidate step.</summary>
public enum AiFailoverAttemptOutcome
{
    /// <summary>This step was the primary route and it was used.</summary>
    PrimarySucceeded = 0,

    /// <summary>This step was selected and its invocation succeeded.</summary>
    AlternateSucceeded = 1,

    /// <summary>This step was attempted and failed.</summary>
    Attempted = 2,

    /// <summary>This step was considered and refused before any invocation.</summary>
    Rejected = 3,
}

/// <summary>
/// The whole failover record for one execution: the chain, the decisions and the outcome.
/// </summary>
/// <remarks>
/// <para>
/// <b><see cref="UsedFallback"/> is the field an operations surface alerts on.</b> A spend increase,
/// a latency increase or a failure-rate change caused by failover has to be separable from one
/// caused by the primary route, and this is the only thing that tells them apart after the fact.
/// </para>
/// <para>
/// <see cref="ReasonCode"/> is the terminal code — why the failover stopped — and the per-step codes
/// on <see cref="Attempts"/> are why each step went the way it did. Both are needed: the terminal
/// code answers "why is this execution on its fallback", the step codes answer "why not the one I
/// expected".
/// </para>
/// </remarks>
public sealed record AiFailoverDecision
{
    /// <summary>The primary route the router selected.</summary>
    public required AiRoutingCandidate Primary { get; init; }

    /// <summary>Every step considered, in order, starting with the primary.</summary>
    public IReadOnlyList<AiFailoverAttempt> Attempts { get; init; } = [];

    /// <summary>The route actually used, or null when nothing was reachable.</summary>
    public AiRoutingCandidate? Selected { get; init; }

    /// <summary>Why the failover stopped.</summary>
    public required AiFailoverReasonCode ReasonCode { get; init; }

    /// <summary>A caller-safe explanation of the terminal code.</summary>
    public string? Reason { get; init; }

    /// <summary>True when the selected route is not the primary.</summary>
    public bool UsedFallback => Selected is { } selected
        && !string.Equals(selected.ModelId, Primary.ModelId, StringComparison.Ordinal);

    /// <summary>True when a route other than the primary was actually attempted.</summary>
    /// <remarks>
    /// <para>
    /// <b>W7G-R corrected this, and the member's own summary is what it was corrected against.</b> The
    /// test was <c>Outcome is Attempted or AlternateSucceeded</c>, and
    /// <see cref="AiFailoverAttemptOutcome.Attempted"/> is the outcome a failed <em>primary</em> gets —
    /// the governed path assigns <see cref="AiFailoverAttemptOutcome.PrimarySucceeded"/> when the
    /// primary succeeds and <see cref="AiFailoverAttemptOutcome.Attempted"/> when it was invoked and
    /// did not. So an execution whose primary failed and whose chain was then exhausted, with no
    /// alternate ever called, reported <c>AttemptedAlternate = true</c>: the one case where an operator
    /// most needs to distinguish "nothing else was tried" from "something else was tried", answered
    /// wrongly, and answered wrongly in the direction that looks like resilience.
    /// </para>
    /// <para>
    /// The primary is excluded by identity rather than by position, matching
    /// <see cref="UsedFallback"/>, so the member does not depend on the ordering convention holding —
    /// and <see cref="Order"/> is not consulted, because a record whose order field was ever written
    /// differently would silently change what this property means.
    /// </para>
    /// </remarks>
    public bool AttemptedAlternate => Attempts.Any(a =>
        a.Outcome is AiFailoverAttemptOutcome.Attempted or AiFailoverAttemptOutcome.AlternateSucceeded
        && !IsPrimary(a));

    /// <summary>True when this attempt was against the primary route.</summary>
    /// <remarks>
    /// Matched on the model and provider together, as the selector's own
    /// <c>AlreadyAttempted</c> is: one model can be served by two providers and those are two routes.
    /// </remarks>
    private bool IsPrimary(AiFailoverAttempt attempt)
        => string.Equals(attempt.ModelId, Primary.ModelId, StringComparison.Ordinal)
            && string.Equals(attempt.ProviderId, Primary.ProviderId, StringComparison.Ordinal);

    /// <summary>Every step that was refused before invocation.</summary>
    public IReadOnlyList<AiFailoverAttempt> Rejected => [.. Attempts.Where(a => a.Outcome is AiFailoverAttemptOutcome.Rejected)];

    /// <summary>
    /// Builds the record for an execution that never needed to fail over.
    /// </summary>
    /// <remarks>
    /// A one-step record rather than no record. Every execution has a failover decision, including
    /// the overwhelming majority where the decision was "the primary was healthy and was used" —
    /// otherwise the operations surface would have to distinguish "no failover happened" from "the
    /// failover plane did not run", and those are different facts.
    /// </remarks>
    public static AiFailoverDecision NotNeeded(AiRoutingCandidate primary, DateTimeOffset at) => new()
    {
        Primary = primary,
        Selected = primary,
        ReasonCode = AiFailoverReasonCode.HealthyRoute,
        Reason = "The primary route was healthy and served the request.",
        Attempts =
        [
            new AiFailoverAttempt
            {
                Order = 0,
                ModelId = primary.ModelId,
                ProviderId = primary.ProviderId,
                Outcome = AiFailoverAttemptOutcome.PrimarySucceeded,
                ReasonCode = AiFailoverReasonCode.HealthyRoute,
                Detail = "The primary route was used and did not fail.",
                Governance = primary.Governance,
                At = at,
            },
        ],
    };
}

/// <summary>
/// Chooses the next route to attempt after a failure, from the router's governed fallback chain.
/// </summary>
/// <remarks>
/// <para>
/// <b>It reads the chain the router produced and cannot invent candidates.</b> Every member of an
/// <see cref="AiRoutingOutcome.FallbackChain"/> was individually permitted by governance for this
/// exact request, and that is the structural guarantee that a failover cannot bypass policy — not a
/// check inside the selector, which would be a check someone could later reorder.
/// </para>
/// <para>
/// <b>It may refuse a chain member the router permitted.</b> Health, reliability and budget are
/// re-read at attempt time, because a chain computed before the first attempt is stale by the time
/// the first attempt fails — and the whole point of failing over is that something changed.
/// </para>
/// <para>
/// <b>It never moves on a governance refusal.</b> A route refused by policy is reported as
/// <see cref="AiFailoverReasonCode.GovernanceBlockNotFailover"/> and the failover stops. Searching
/// for a route policy has not yet refused would convert a deliberate refusal into a silent
/// workaround, which is the single most damaging thing a fallback could do.
/// </para>
/// </remarks>
public interface IAiFailoverSelector
{
    /// <summary>
    /// Chooses the next route to attempt, or null when none remains.
    /// </summary>
    /// <param name="request">The capability request, for identity and the operational gates to re-read.</param>
    /// <param name="routing">
    /// The routing context the router decided with, so the operational gates re-read exactly what the
    /// routing decision read. Passing anything else would let a failover evaluate a candidate against a
    /// different size, tier or modality than the one that admitted it.
    /// </param>
    /// <param name="outcome">The router's outcome, whose fallback chain bounds what may be tried.</param>
    /// <param name="attempts">What has been attempted so far, in order, primary first.</param>
    /// <param name="failure">Why the most recent attempt failed, or null when it was never attempted.</param>
    /// <param name="at">The instant the decision is being made, for window and staleness evaluation.</param>
    AiFailoverStep Next(
        AiCapabilityRequest request,
        AiRoutingContext routing,
        AiRoutingOutcome outcome,
        IReadOnlyList<AiFailoverAttempt> attempts,
        AiFailure? failure,
        DateTimeOffset at);
}

/// <summary>The failover selector's answer for one step.</summary>
public sealed record AiFailoverStep
{
    /// <summary>The route to attempt, or null when none remains.</summary>
    public AiRoutingCandidate? Candidate { get; init; }

    /// <summary>
    /// What the operational gates concluded about <see cref="Candidate"/>, where a route was chosen.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>W7G-R added this, and its absence was the reason a fallback's own budget decision could not
    /// be read back.</b> Every chain member is re-evaluated against the live operational gates before
    /// it is used — tier, reliability and cost — and the verdict that admitted it was discarded on the
    /// way out while the record of it was kept only when the member was <em>refused</em>. So the estate
    /// could say what a fallback was refused for and never what it was admitted on, which is the
    /// half that matters for a route that actually spends money.
    /// </para>
    /// <para>
    /// Carried rather than recomputed. A reader that re-evaluated the gates would get a second answer
    /// to a question already answered, taken at a different moment against evidence that has moved on.
    /// </para>
    /// <para>
    /// Null when no route was chosen, which is the exhausted and stopped cases.
    /// </para>
    /// </remarks>
    public AiOperationalVerdict? Operational { get; init; }

    /// <summary>Why the selector stopped, or why it moved on.</summary>
    public required AiFailoverReasonCode ReasonCode { get; init; }

    /// <summary>A caller-safe explanation.</summary>
    public required string Detail { get; init; }

    /// <summary>
    /// The reasons each intervening chain member was skipped, so none is silently bypassed.
    /// </summary>
    /// <remarks>
    /// A skipped candidate with no recorded reason is indistinguishable from one that was never in
    /// the chain, and "the fallback did not try the route I expected" is the first question asked
    /// after a degradation.
    /// </remarks>
    public IReadOnlyList<AiFailoverAttempt> Skipped { get; init; } = [];

    /// <summary>True when a route was chosen.</summary>
    public bool HasCandidate => Candidate is not null;
}
