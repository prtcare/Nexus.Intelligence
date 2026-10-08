namespace Nexus.Intelligence.Contracts;

/// <summary>
/// Turns a capability request into a governed route, or into a typed refusal.
/// </summary>
/// <remarks>
/// <para>
/// <b>The only routing path, and the reason a caller never names a provider.</b> A caller states a
/// capability and the size and shape of its work; this port resolves which model and provider serve
/// it. There is no overload that accepts a model or a provider, and there must never be one: an
/// overload that did would be the second routing path the directive forbids, and every guarantee this
/// lane makes — governance first, health second, no blocked fallback — would hold on one path and not
/// the other.
/// </para>
/// <para>
/// <b>Selection is synchronous and pure.</b> The same request, registry, health snapshot, policy and
/// governance tables produce byte-identical outcomes, and a test asserts it. Asynchrony here would
/// admit an implementation that reached a network from inside a routing decision, which would put an
/// I/O operation in front of the gate that is supposed to precede all I/O, and would make the estate's
/// routing depend on the weather.
/// </para>
/// <para>
/// <b>This port selects; it does not invoke.</b> Executing the selection is the AI Head's
/// governed-invocation seam — the one that takes this outcome's
/// <see cref="AiRoutingCandidate.Governance"/> decision and re-checks it before calling anything.
/// Keeping the two apart is what allows routing to be tested exhaustively with no provider present,
/// and it means the invoke-time gate is not a second implementation of the routing gate: it is the
/// same decision object, re-read.
/// </para>
/// </remarks>
public interface IAiCapabilityRouter
{
    /// <summary>
    /// Resolves a governed route for a capability request.
    /// </summary>
    /// <param name="request">What the caller asked for. Carries no provider, model or credential.</param>
    /// <param name="platform">
    /// The deterministic platform authority's attestation for the action this work belongs to.
    /// Required, and deliberately not optional: a routing decision that omitted it would be evaluating
    /// a governance question with an input missing, and an omitted attestation reads as "no platform
    /// action attached" rather than as "somebody forgot".
    /// </param>
    /// <param name="context">
    /// What the AI Head knows about the work. Pass <see cref="AiRoutingContext.Unstated"/> to state
    /// nothing; there is no default, so stating nothing is a decision rather than an oversight.
    /// </param>
    /// <returns>
    /// An outcome that is either a selection with its evidence, or a typed refusal naming the gate
    /// that fired. Never null, and never a selection that governance did not permit.
    /// </returns>
    AiRoutingOutcome Route(
        AiCapabilityRequest request,
        AiPlatformGovernanceAttestation platform,
        AiRoutingContext context);
}
