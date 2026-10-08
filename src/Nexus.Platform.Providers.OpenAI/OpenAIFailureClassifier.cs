using System.ClientModel;
using System.Net;
using System.Text.Json;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Platform.Providers.OpenAI;

/// <summary>
/// Turns the OpenAI SDK's failure vocabulary into the estate's provider-neutral one.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the only place in the estate that is allowed to know an OpenAI status code means
/// anything.</b> Everything above this file sees <see cref="ModelFailureKind"/> and nothing else, which
/// is what makes swapping the vendor a configuration change: a second adapter classifies its own
/// failures and the layers above are untouched, because they were never reading an OpenAI-shaped fact.
/// </para>
/// <para>
/// <b>It is a pure function of an exception, deliberately.</b> No provider is contacted and no clock is
/// read, so every mapping below is provable by a deterministic test with no live credential — which
/// matters because a mapping that can only be exercised against a real vendor is a mapping that is
/// exercised in production for the first time.
/// </para>
/// <para>
/// <b>Exceptions are classified; their text never is.</b> Nothing here reads
/// <see cref="Exception.Message"/>. The message is provider vocabulary — it can carry a model name, an
/// endpoint, an account identifier or a request id — and it is matched against nothing, because a
/// classifier that pattern-matched on vendor prose would be re-leaking through a private channel
/// exactly what the boundary exists to contain. Only the exception's <em>type</em> and, where the SDK
/// supplies one, its transport <em>status code</em> are consulted.
/// </para>
/// <para>
/// <b>Where a status has no honest target it is left unclassified rather than forced.</b> See
/// <see cref="FromStatus"/> — the closing rows are the interesting ones.
/// </para>
/// </remarks>
public static class OpenAIFailureClassifier
{
    /// <summary>
    /// The classification for a failure raised by an invocation.
    /// </summary>
    /// <param name="exception">The exception the adapter caught. Only its type is consulted.</param>
    /// <param name="ct">
    /// The caller's token, read only to distinguish a cancellation the caller asked for from a deadline
    /// the transport imposed. Both are <see cref="ModelFailureKind.Timeout"/> — neither produced an
    /// answer — but the distinction is why this parameter is here rather than assumed away.
    /// </param>
    public static ModelFailureKind Classify(Exception exception, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(exception);

        return exception switch
        {
            // Covers the caller's own cancellation and the SDK's internal HTTP timeout: the second is a
            // TaskCanceledException whose token was never cancelled, which is why `ct` cannot be used to
            // decide the outcome — only to explain it.
            OperationCanceledException => ModelFailureKind.Timeout,

            // The transport never reached a decision — DNS, TLS, connection reset, socket timeout.
            HttpRequestException => ModelFailureKind.ProviderUnavailable,

            // A response arrived and could not be read as the contract it claimed to be. That is the
            // taxonomy's "an answer was produced and rejected", not an unavailability: retrying the same
            // request is as likely to produce the same unreadable body.
            JsonException => ModelFailureKind.InvalidOutput,

            // The SDK's own error envelope. Its status is the only vendor-supplied fact read anywhere in
            // this file.
            ClientResultException client => FromStatus(client.Status),

            // Anything else is a failure this adapter cannot name. ProviderUnavailable is the estate's
            // pre-classification posture for a permitted call that did not complete, and it is retryable,
            // so an unrecognised failure still reaches the failover plane instead of becoming terminal.
            _ => ModelFailureKind.ProviderUnavailable,
        };
    }

    /// <summary>
    /// The classification for the HTTP status a provider returned.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Two rows deserve their reasoning stated, because both are places where an obvious mapping is the
    /// wrong one.
    /// </para>
    /// <para>
    /// <b>401 and 403 are an unavailability, not a policy block.</b> It is tempting to read an
    /// authentication refusal as the provider making a decision, and to route it to
    /// <see cref="ModelFailureKind.PolicyBlocked"/> — which is not retryable. That would be a serious
    /// mis-mapping for this estate: a credential that a <em>provider</em> rejects is a fact about one
    /// provider, and the estate's remedy is to fail over to another provider holding its own working
    /// credential. Marking it non-retryable would turn a single misconfigured key into a total outage
    /// for every capability routed through that provider. <see cref="ModelFailureKind.PolicyBlocked"/> is
    /// reserved for the estate's own refusals, which is where it is produced and where it is correct.
    /// </para>
    /// <para>
    /// <b>A 429 is an unavailability.</b> The provider is reachable and is declining to serve right now.
    /// The remedy is the same as for any other temporary unavailability — wait, or use another provider —
    /// which is exactly what a retryable category means.
    /// </para>
    /// <para>
    /// <b>The default row is <see cref="ModelFailureKind.Unspecified"/>, not a guess.</b> A status with
    /// no honest target in the closed set — a malformed request, a conflict, a vendor-specific code — is
    /// reported as classified-but-unmapped. Forcing it into a nearby member would invent a fact
    /// ("the model is gone", "the provider is down") that the status does not support, and a reader
    /// would have no way to tell an inferred category from an observed one. Unspecified is the member
    /// that exists to make this gap visible, and downstream it resolves to the same category every
    /// unclassified failure does.
    /// </para>
    /// </remarks>
    public static ModelFailureKind FromStatus(int status) => status switch
    {
        // Reachable, and finished the exchange without producing an answer in time.
        (int)HttpStatusCode.RequestTimeout => ModelFailureKind.Timeout,

        // Reachable, and declined to serve this caller. See the remarks: retryable on purpose.
        (int)HttpStatusCode.Unauthorized or
        (int)HttpStatusCode.Forbidden or
        (int)HttpStatusCode.TooManyRequests => ModelFailureKind.ProviderUnavailable,

        // Reachable, and does not serve this model.
        (int)HttpStatusCode.NotFound => ModelFailureKind.ModelUnavailable,

        // The provider is not serving. This is the ordinary outage the failover plane exists for.
        >= 500 => ModelFailureKind.ProviderUnavailable,

        _ => ModelFailureKind.Unspecified,
    };
}
