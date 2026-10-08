namespace Nexus.Intelligence.Contracts;

/// <summary>
/// Publishes whether the AI Head can serve work, as a conclusion rather than as the evidence behind it.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the server half of the availability contract, and it deliberately returns the projected
/// answer rather than the inputs to it.</b> An implementation reads the estate's health snapshots, its
/// registries, its reliability history and its policy, and answers with
/// <see cref="AiGatewayAvailability"/> — which names no provider, no model and no health state. The
/// obvious alternative, a port that exposed the health snapshot store and let the transport project it,
/// would put the projection in the API layer where it would have to be repeated by every transport and
/// where the first added transport would publish something different. It would also mean the API layer
/// holds a reference to provider health, which is one refactor away from a caller-facing type that
/// carries it.
/// </para>
/// <para>
/// <b>The projection is not a simplification of the truth; it is a different statement.</b>
/// "Provider <c>prov-a</c> reports Degraded and its circuit is half-open" and "capability
/// <c>code.review</c> can be served with reduced redundancy" are not the same claim, and neither is a
/// summary of the other. The first is an operator's finding, the second is a caller's decision input.
/// This port produces the second and the operations read model already produces the first.
/// </para>
/// <para>
/// <b>Read-only, synchronous and side-effect free.</b> Read-only because availability is not something
/// a caller sets. Synchronous because the store it reads is in-memory and a probe that reached the
/// network would put I/O on the path a caller takes when deciding whether to call at all — the one
/// place a slow answer is worse than no answer. Side-effect free because a caller polling this must not
/// thereby change what it reports; an availability probe that updated the health it read would make
/// every Product's health check a write to the estate's health plane.
/// </para>
/// </remarks>
public interface IAiGatewayAvailabilitySource
{
    /// <summary>
    /// The AI Head's availability, and the availability of every capability it knows about.
    /// </summary>
    /// <remarks>
    /// Never null and never empty of <see cref="AiGatewayAvailability.Capabilities"/> when the estate
    /// has registered anything: a capability the Head knows about but cannot serve appears with an
    /// unservable state, because "absent" and "unavailable" are different answers and a caller cannot
    /// tell which one an omission meant.
    /// </remarks>
    AiGatewayAvailability Read();

    /// <summary>
    /// The availability of one capability, or null when the AI Head does not recognise it.
    /// </summary>
    /// <remarks>
    /// Returns the same record the full read carries, so a caller that asks about one capability and a
    /// caller that reads the document cannot be told different things. The overload exists so that a
    /// single-capability transport does not have to compose a document it will discard — not so that it
    /// can answer differently.
    /// <para>
    /// <b>Null, not an unservable entry, and the distinction is the one
    /// <see cref="AiGatewayAvailability.CapabilityFor"/> draws.</b> An unrecognised identifier is a
    /// caller asking for something that does not exist, which no amount of waiting will change; an
    /// entry with <see cref="AiAvailabilityState.Unavailable"/> would tell that caller the service is
    /// momentarily down and send it to retry a request that can never succeed.
    /// </para>
    /// </remarks>
    AiCapabilityAvailability? Read(CapabilityId capability);
}
