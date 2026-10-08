namespace Nexus.Intelligence.Contracts;

/// <summary>
/// Whether the AI Head can serve work, as a caller can act on it.
/// </summary>
/// <remarks>
/// <para>
/// <b>Four states, because three of them are different caller behaviours.</b>
/// <see cref="Available"/> means proceed. <see cref="Unavailable"/> means take the deterministic path
/// now rather than waiting — a caller that retries an unavailable Head is spending its own latency on
/// a question already answered. <see cref="Degraded"/> means proceed, expecting a
/// <see cref="AiExecutionStatus.Degraded"/> or reduced-quality answer rather than a refusal, which is
/// a different decision from either. <see cref="Unknown"/> means nobody has established anything:
/// the probe has not run, or its last sweep produced nothing usable.
/// </para>
/// <para>
/// <b><see cref="Unknown"/> is not <see cref="Unavailable"/>, and collapsing them is the defect this
/// member prevents.</b> A caller that read "we never checked" as "it is down" would take the
/// deterministic path during every startup and every probe-window outage of the monitoring plane
/// itself; a caller that read it as "it is up" would attempt work it cannot complete. The honest
/// answer to "have you checked" is that nobody has, and it is stated here rather than filled in with
/// whichever guess a caller finds more convenient.
/// </para>
/// </remarks>
public enum AiAvailabilityState
{
    /// <summary>Nothing has established this. Not a synonym for available or for unavailable.</summary>
    Unknown = 0,

    /// <summary>The capability can be served.</summary>
    Available = 1,

    /// <summary>Work can be served, but not at the quality or by the path the caller would expect.</summary>
    Degraded = 2,

    /// <summary>Work cannot be served. The caller should take its deterministic path.</summary>
    Unavailable = 3,
}

/// <summary>
/// Why availability is what it is, in provider-neutral terms.
/// </summary>
/// <remarks>
/// <para>
/// <b>A closed vocabulary rather than free text, and that is a security decision as much as a design
/// one.</b> The obvious alternative is a <c>Detail</c> string, and the first useful thing anyone would
/// put in it is <c>"provider prod-a-east is returning 503"</c> — which names a provider, implies a
/// vendor, discloses an outage window, and turns a caller-facing contract into a monitoring feed. A
/// caller needs to know what it should <em>do</em>; which route is unhealthy is an operator's
/// business and is already answerable under authority through the operations read model.
/// </para>
/// <para>
/// <see cref="None"/> is the reason that accompanies <see cref="AiAvailabilityState.Available"/> and
/// <see cref="AiAvailabilityState.Unknown"/>, where there is nothing to explain.
/// </para>
/// </remarks>
public enum AiAvailabilityReason
{
    /// <summary>Nothing to explain. Accompanies an available or unknown state.</summary>
    None = 0,

    /// <summary>No route for this capability is configured on this AI Head at all.</summary>
    NotConfigured = 1,

    /// <summary>Routes exist and every one of them is currently unfit to serve.</summary>
    NoUsableRoute = 2,

    /// <summary>A route is usable, but only one that the caller's policy would not prefer.</summary>
    ReducedRedundancy = 3,

    /// <summary>Policy refuses this capability for this caller's classification or scope.</summary>
    PolicyRestricted = 4,

    /// <summary>Budget has been exhausted for the scope this caller is attributed to.</summary>
    BudgetExhausted = 5,

    /// <summary>The AI Head is deliberately not serving, e.g. during maintenance.</summary>
    Maintenance = 6,

    /// <summary>Observed reliability on the usable routes is below the estate's threshold.</summary>
    ReliabilityBelowThreshold = 7,

    /// <summary>No health information has been published, so no route can be called usable.</summary>
    HealthUnpublished = 8,
}

/// <summary>
/// Whether one capability can be served, and in what terms.
/// </summary>
/// <remarks>
/// Addressed by <see cref="CapabilityId"/>, which is the only identifier a caller is entitled to
/// reason about. There is deliberately no model, provider, vendor, region or endpoint member here,
/// and there is no plan to add one: a caller that could see which route would serve its request is a
/// caller that would eventually prefer one.
/// </remarks>
public sealed record AiCapabilityAvailability
{
    /// <summary>The capability this is about.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>Whether it can be served.</summary>
    public required AiAvailabilityState State { get; init; }

    /// <summary>Why, in provider-neutral terms. <see cref="AiAvailabilityReason.None"/> when there is nothing to say.</summary>
    public AiAvailabilityReason Reason { get; init; } = AiAvailabilityReason.None;

    /// <summary>True when a caller may proceed and receive an answer.</summary>
    /// <remarks>
    /// Stated as a member rather than left as <c>State is Available or Degraded</c> at every call site.
    /// A caller that must remember which of four states are the proceedable ones will eventually treat
    /// <see cref="AiAvailabilityState.Degraded"/> as a refusal and skip a usable path, or treat
    /// <see cref="AiAvailabilityState.Unknown"/> as proceedable and attempt work nobody has said can
    /// be served.
    /// </remarks>
    public bool IsServable => State is AiAvailabilityState.Available or AiAvailabilityState.Degraded;
}

/// <summary>
/// Whether the AI Head can serve work, and which capabilities it can serve.
/// </summary>
/// <remarks>
/// <para>
/// <b>The cross-Head availability contract.</b> A consumer asks two questions — is the Head there, and
/// can it do the thing I want — and this answers both without disclosing how the AI Head is built. It
/// is a projection of the estate's own health, reliability and registry state, composed on the AI Head's
/// side and published as a conclusion; the provider-level facts it rests on are not part of it.
/// </para>
/// <para>
/// <b>It is a snapshot with a time on it, not a subscription.</b> A caller that caches this must know
/// when it was taken, because an availability answer with no timestamp is indistinguishable from one
/// taken an hour ago — and the whole value of asking is that the answer may have changed. Callers that
/// need to know <em>when</em> it changes rather than <em>whether</em> it is currently true should ask
/// again; the estate publishes health to its own operators through the operations surface, and pushing
/// that to every Product would put an outage feed in every consumer.
/// </para>
/// <para>
/// <b>The per-capability list is the whole list, not a filtered one.</b> A caller asking about one
/// capability receives the same document every other caller receives, and finds its own entry. A
/// document whose contents depended on what the caller asked about would be a document whose absence
/// of an entry meant two different things.
/// </para>
/// </remarks>
public sealed record AiGatewayAvailability
{
    /// <summary>Whether the AI Head as a whole can serve work.</summary>
    public required AiAvailabilityState State { get; init; }

    /// <summary>Why, in provider-neutral terms.</summary>
    public AiAvailabilityReason Reason { get; init; } = AiAvailabilityReason.None;

    /// <summary>When this was observed. Never absent: an undated availability claim is not an answer.</summary>
    public required DateTimeOffset ObservedAt { get; init; }

    /// <summary>The contract version the answering gateway serves.</summary>
    /// <remarks>
    /// Carried here as well as in <see cref="AiGatewayContract.VersionHeader"/> because availability is
    /// the one call a caller makes before it knows anything about the Head, and a caller whose only
    /// question is "is this the contract I was built against" should not have to spend a capability
    /// invocation to ask it.
    /// </remarks>
    public string ContractVersion { get; init; } = AiGatewayContract.Version;

    /// <summary>Every capability the AI Head knows about, with its own availability.</summary>
    public IReadOnlyList<AiCapabilityAvailability> Capabilities { get; init; } = [];

    /// <summary>True when the Head can serve work, with or without reduced quality.</summary>
    public bool IsServable => State is AiAvailabilityState.Available or AiAvailabilityState.Degraded;

    /// <summary>The availability of one capability, or null when the Head does not know it.</summary>
    /// <remarks>
    /// <para>
    /// Null means the AI Head does not recognise the identifier, which is a different finding from
    /// <see cref="AiAvailabilityState.Unavailable"/> and must not be reported as one: an unrecognised
    /// capability is a caller that has asked for something that does not exist, and telling it the
    /// service is down would send it to retry a request that can never succeed. The typed failure for
    /// that case is <see cref="AiFailureCategory.CapabilityNotFound"/>, raised when the capability is
    /// actually invoked.
    /// </para>
    /// <para>
    /// A linear scan over a list that holds one entry per registered capability. The alternative — a
    /// second, keyed index maintained beside this one — is the second source of truth this estate
    /// avoids everywhere else.
    /// </para>
    /// </remarks>
    public AiCapabilityAvailability? CapabilityFor(CapabilityId capability)
    {
        foreach (var entry in Capabilities)
        {
            if (entry.Capability == capability)
            {
                return entry;
            }
        }

        return null;
    }
}
