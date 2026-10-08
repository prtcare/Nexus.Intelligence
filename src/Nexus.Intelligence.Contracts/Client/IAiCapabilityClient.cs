namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The stable surface through which Products, Forge and Platform ask the AI Head for work.
/// </summary>
/// <remarks>
/// <para>
/// This is the client-side half of the V3 AI boundary and the successor to the turn-shaped part of
/// <see cref="IIntelligenceClient"/>. A caller invokes a <b>semantic capability</b> and receives a
/// result that names no provider and no model. Everything that decides <em>how</em> the work is done
/// sits behind this interface.
/// </para>
/// <para>
/// <b>This type is the boundary, and it has two roles.</b> A <em>consumer</em> implements it as
/// transport: it resolves the AI Head endpoint, serialises the request, and maps the response, and it
/// must not select a provider, hold a provider credential, apply a routing rule, interpret a model
/// identifier, or retry on the caller's behalf because a provider failed — retry and failover are the
/// AI Head's business, and a client that performs them has taken a decision it cannot see the whole
/// of. The AI Head implements it as the <em>serving</em> role, translating a semantic request onto its
/// own governed execution path and projecting the outcome back.
/// </para>
/// <para>
/// <b>One interface with two roles rather than two interfaces with one shape each.</b> The alternative
/// is a server-side port declaring the same two methods, which would be a second definition of the
/// same contract: two shapes to keep in step, drifting the first time only one of them changed, and
/// two answers to "what is the AI capability boundary" for a consumer to choose between. The methods
/// below say what a caller may ask and what it receives; nothing in them is specific to either side
/// of the wire, which is why they carry both.
/// </para>
/// <para>
/// The existing <see cref="IIntelligenceClient"/> remains for conversational turns and is not replaced
/// by this interface in W7A. Both may be implemented by one transport class; they are separate
/// interfaces because a capability invocation and a turn have different envelopes, and merging them
/// would force every capability caller to construct turn-shaped input.
/// </para>
/// </remarks>
public interface IAiCapabilityClient
{
    /// <summary>
    /// Invokes a capability.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Returns rather than throws for every AI-side failure.</b> A policy refusal, an unavailable
    /// provider, a budget block and a timeout all arrive as a non-success
    /// <see cref="AiCapabilityResponse"/> carrying a typed <see cref="AiFailure"/>. This is deliberate:
    /// an <see cref="AiDependencyClass.AiOptional"/> caller must be able to continue on its
    /// deterministic path without wrapping every call in a try/catch, and a caller forced into
    /// exception handling is a caller that will eventually swallow the wrong exception.
    /// </para>
    /// <para>
    /// An implementation may still throw for a <em>caller</em> defect — a malformed request, a
    /// cancelled token — because those are not AI failures and have no business being reported as one.
    /// </para>
    /// </remarks>
    /// <exception cref="ArgumentException">The request is malformed or missing a required field.</exception>
    /// <exception cref="OperationCanceledException">The operation was cancelled by the caller.</exception>
    Task<AiCapabilityResponse> InvokeAsync(AiCapabilityRequest request, CancellationToken ct = default);

    /// <summary>
    /// Lists the capabilities this AI Head will serve.
    /// </summary>
    /// <remarks>
    /// Returns capability identifiers and their governance facts — <b>never models, vendors, agent
    /// identifiers or tool identifiers</b>. The caller learns what Nexus can <em>do</em>, not what
    /// Nexus rents. The route that used to answer with the model catalogue,
    /// <c>GET /intelligence/v1/capabilities</c>, was retired in W7F: it now answers <c>410 Gone</c>
    /// naming its replacement rather than serving a narrowed body a consumer could mistake for an
    /// empty estate. <c>CapabilitiesEndpoints</c> records why the route was refused rather than
    /// re-pointed.
    /// </remarks>
    Task<IReadOnlyList<AiCapabilityRegistration>> ListCapabilitiesAsync(CancellationToken ct = default);
}
