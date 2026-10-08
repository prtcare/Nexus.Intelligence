namespace Nexus.Intelligence.Contracts;

/// <summary>
/// What one probe observed about one target at one instant.
/// </summary>
/// <remarks>
/// <para>
/// <b>An observation is evidence, and evidence has a time.</b> <see cref="ObservedAt"/> is required
/// because the operations plane must be able to answer "how stale is the health this routing
/// decision used", and a snapshot with no timestamps cannot distinguish a provider that recovered
/// ten seconds ago from one that recovered an hour ago.
/// </para>
/// <para>
/// <b><see cref="Detail"/> is caller-safe and must never be a provider error body.</b> A probe
/// reaches a provider, so it is exactly the place where an upstream message carrying a model name,
/// an endpoint or a request identifier could enter the estate's records. It is written by the
/// probe, in the probe's own words, and it is not a captured exception.
/// </para>
/// </remarks>
public sealed record AiHealthObservation
{
    /// <summary>The provider the observation is about.</summary>
    public required string ProviderId { get; init; }

    /// <summary>The model the observation is about, or null for a provider-wide observation.</summary>
    public string? ModelId { get; init; }

    /// <summary>What the probe concluded.</summary>
    public required AiHealthProbeOutcome Outcome { get; init; }

    /// <summary>
    /// The state to publish, present exactly when <see cref="Outcome"/> is
    /// <see cref="AiHealthProbeOutcome.Observed"/>.
    /// </summary>
    public AiModelHealthState? State { get; init; }

    /// <summary>The probe that produced this observation, by identifier.</summary>
    public required string ProbeId { get; init; }

    /// <summary>When the observation was taken.</summary>
    public required DateTimeOffset ObservedAt { get; init; }

    /// <summary>How long the probe took. Feeds the reliability indicators; never a caller-facing figure.</summary>
    public TimeSpan? Duration { get; init; }

    /// <summary>A caller-safe description. Never a provider error body.</summary>
    public string? Detail { get; init; }

    /// <summary>True when this observation carries a state to publish.</summary>
    public bool HasState => Outcome is AiHealthProbeOutcome.Observed && State is not null;

    /// <summary>An observation that ran and concluded nothing.</summary>
    public static AiHealthObservation Inconclusive(
        string providerId, string? modelId, string probeId, DateTimeOffset at, string detail) => new()
        {
            ProviderId = providerId,
            ModelId = modelId,
            Outcome = AiHealthProbeOutcome.Inconclusive,
            ProbeId = probeId,
            ObservedAt = at,
            Detail = detail,
        };

    /// <summary>An observation that ran and produced a state.</summary>
    public static AiHealthObservation Observed(
        string providerId,
        string? modelId,
        string probeId,
        DateTimeOffset at,
        AiModelHealthState state,
        string? detail = null) => new()
        {
            ProviderId = providerId,
            ModelId = modelId,
            Outcome = AiHealthProbeOutcome.Observed,
            State = state,
            ProbeId = probeId,
            ObservedAt = at,
            Detail = detail,
        };
}

/// <summary>What a probe is asked to look at.</summary>
/// <remarks>
/// <b>Deliberately minimal, and deliberately credential-free.</b> A probe is handed a provider and a
/// model identifier and nothing else. There is no secret reference on this type and there must not
/// be: a probe receives its own configuration out of band, so that the estate's routing composition
/// never holds a value it does not need — and so that a probe cannot be written which reads a
/// credential merely because it was passed one.
/// </remarks>
public sealed record AiHealthProbeTarget
{
    /// <summary>The provider to probe.</summary>
    public required string ProviderId { get; init; }

    /// <summary>The model to probe, or null for a provider-wide probe.</summary>
    public string? ModelId { get; init; }
}

/// <summary>
/// Something that can determine whether a provider or model is currently usable.
/// </summary>
/// <remarks>
/// <para>
/// <b>Asynchronous, because a probe reaches the network — and that is precisely why it is a separate
/// type from <see cref="IAiModelHealthSource"/>.</b> Routing reads a snapshot synchronously; probing
/// writes to it asynchronously from outside any routing decision. One interface that did both would
/// be an interface whose synchronous method could be implemented by reaching a provider, and the
/// routing path would acquire a network call without anyone editing the router.
/// </para>
/// <para>
/// <b>A probe may refuse to conclude.</b> <see cref="AiHealthProbeOutcome.Inconclusive"/> exists so
/// that a probe which cannot tell does not have to guess a state, and
/// <see cref="AiHealthProbeOutcome.NotProbed"/> so an estate with no probe configured is not
/// mistaken for one with a failing probe.
/// </para>
/// <para>
/// <b>The estate ships no probe that requires the historical provider credential.</b> The default
/// composition configures none, every target therefore reports
/// <see cref="AiHealthProbeOutcome.NotProbed"/>, and the published state remains whatever the
/// registry declared. Tests use fakes. No test requires a credential.
/// </para>
/// </remarks>
public interface IAiHealthProbe
{
    /// <summary>The probe's stable identifier, recorded on every observation it produces.</summary>
    string ProbeId { get; }

    /// <summary>Whether this probe handles a given target.</summary>
    bool Handles(AiHealthProbeTarget target);

    /// <summary>Observes a target. Must not throw: a probe that throws is reported as inconclusive.</summary>
    ValueTask<AiHealthObservation> ProbeAsync(AiHealthProbeTarget target, CancellationToken cancellationToken);
}

/// <summary>
/// The health the estate currently believes, as one immutable value.
/// </summary>
/// <remarks>
/// <para>
/// <b>A snapshot rather than a live map, because routing must not observe a health state that
/// changes halfway through a decision.</b> Every candidate in one routing decision is evaluated
/// against the same snapshot, so the decision is reproducible from the snapshot alone — which is the
/// property <see cref="IAiCapabilityRouter"/>'s contract already claims and which a mutable
/// dictionary read during the loop would quietly break.
/// </para>
/// <para>
/// <b>Absence of an entry is not health.</b> An unknown model or provider resolves to
/// <see cref="AiModelHealthState.Unknown"/>, which is not routable. A snapshot that answered
/// <see cref="AiModelHealthState.Available"/> for a target nobody probed would be asserting
/// something nobody observed.
/// </para>
/// </remarks>
public sealed record AiHealthSnapshot
{
    /// <summary>When this snapshot was published.</summary>
    public required DateTimeOffset TakenAt { get; init; }

    /// <summary>The probe that produced it, or a marker naming the seed source when it came from configuration.</summary>
    public required string Source { get; init; }

    /// <summary>Provider-wide states, keyed by provider identifier.</summary>
    public IReadOnlyDictionary<string, AiModelHealthState> Providers { get; init; }
        = new Dictionary<string, AiModelHealthState>(StringComparer.Ordinal);

    /// <summary>Model-scoped states, keyed by model and provider.</summary>
    public IReadOnlyDictionary<(string ModelId, string ProviderId), AiModelHealthState> Models { get; init; }
        = new Dictionary<(string, string), AiModelHealthState>();

    /// <summary>When each provider was last observed, where it has been.</summary>
    public IReadOnlyDictionary<string, DateTimeOffset> ProviderObservedAt { get; init; }
        = new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal);

    /// <summary>The provider's state, or <see cref="AiModelHealthState.Unknown"/> when nothing is known.</summary>
    public AiModelHealthState ProviderState(string providerId)
        => Providers.TryGetValue(providerId, out var state) ? state : AiModelHealthState.Unknown;

    /// <summary>
    /// The model's state, falling back to its provider's where the model has none of its own.
    /// </summary>
    /// <remarks>
    /// The fallback is the same one <see cref="ConfiguredAiRegistry"/> already applies and for the
    /// same reason: a model-scoped declaration is the more specific claim and wins, and a model with
    /// neither reports <see cref="AiModelHealthState.Unknown"/> rather than inheriting an
    /// assumption. A provider that is down makes its models unroutable; a model that is down does not
    /// make its siblings unroutable, which is why the fallback runs one way only.
    /// </remarks>
    public AiModelHealthState ModelState(string modelId, string providerId)
    {
        if (Models.TryGetValue((modelId, providerId), out var state))
        {
            return state;
        }

        return ProviderState(providerId);
    }
}

/// <summary>
/// Where the live health snapshot is published and read.
/// </summary>
/// <remarks>
/// <b>One writer, many readers, and a publish that replaces rather than mutates.</b> Publishing a
/// whole snapshot is what makes a reader's view coherent: a reader that observed a map being
/// mutated could see the first half of one probe round and the second half of the next.
/// </remarks>
public interface IAiHealthSnapshotStore
{
    /// <summary>The snapshot readers see. Never null; an empty snapshot is a value.</summary>
    AiHealthSnapshot Current { get; }

    /// <summary>Replaces the current snapshot.</summary>
    void Publish(AiHealthSnapshot snapshot);
}

/// <summary>
/// Runs the configured probes once and publishes the result.
/// </summary>
/// <remarks>
/// <para>
/// <b>Out of band, by construction.</b> Nothing on the routing path holds this type, so no routing
/// decision can await it and no probe can run inside one. That is enforced structurally rather than
/// by a comment in the router, and it is asserted by a test that counts probe invocations across a
/// routing call.
/// </para>
/// <para>
/// <b>It never throws for a failing probe.</b> A probe that throws or returns nothing conclusive
/// leaves the published state for that target exactly as it was, because the alternative — treating
/// a probe crash as unavailability — would let a broken monitoring component take the estate's
/// providers offline.
/// </para>
/// </remarks>
public interface IAiHealthProbeRunner
{
    /// <summary>Runs every configured probe over every target and publishes one snapshot.</summary>
    Task<AiHealthSnapshot> RunOnceAsync(CancellationToken cancellationToken = default);
}
