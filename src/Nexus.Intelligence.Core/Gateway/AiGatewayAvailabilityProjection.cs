using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Gateway;

/// <summary>
/// Projects the AI Head's own health and capability state onto the provider-neutral availability
/// contract callers read.
/// </summary>
/// <remarks>
/// <para>
/// <b>This type is the only place provider health and the caller-facing availability contract meet,
/// and it is deliberately a one-way door.</b> It reads <see cref="IAiHealthSnapshotStore"/> — which
/// names providers, models and their states — and it publishes
/// <see cref="AiGatewayAvailability"/>, which names none of them. TASK 7 forbids exposing raw
/// provider health internals to Product callers, and the structural way to honour that is for the
/// projection to happen below the transport rather than inside it: a transport that held the snapshot
/// store and projected it would put a reference to provider health in the API layer, one added
/// response field away from a caller-facing type that carries one.
/// </para>
/// <para>
/// <b>It answers three questions and refuses the fourth.</b> Is the Head there, can it do the thing
/// I want, and is it degraded — the three TASK 7 names. The question it refuses is <em>which</em>
/// route is unhealthy: that is answerable under authority through the operations read model, and a
/// caller does not act on it. A caller acts on "proceed", "expect less" or "take the deterministic
/// path", and those are three states plus the honest fourth.
/// </para>
/// <para>
/// <b>Unknown is computed rather than assumed, and it is the state most often got wrong.</b> A store
/// holding no providers has not been told anything — not by configuration and not by a probe — and
/// the honest conclusion is that nobody has looked. Reporting that as
/// <see cref="AiAvailabilityState.Available"/> would have every caller attempt work during every
/// startup before the first probe round; reporting it as
/// <see cref="AiAvailabilityState.Unavailable"/> would take the deterministic path during every probe
/// window of the monitoring plane itself. The two errors are opposite and neither is conservative.
/// </para>
/// <para>
/// <b>Reliability is deliberately not read here, and that is a decision rather than an omission.</b>
/// <see cref="IAiReliabilityHistory"/> is per route, and the question "is every route below its
/// threshold" is already answered by <c>GovernedAiOperationalEligibility</c>, which refuses the route
/// rather than the Head. Re-deriving it here would make two components the authority for one
/// judgement, and the availability contract would then be able to say "unavailable" about a Head that
/// was about to serve the request. <see cref="AiAvailabilityReason.ReliabilityBelowThreshold"/> stays
/// in the vocabulary for the lane that gives the registry a route-count-free reliability signal; until
/// then nothing here reaches for one.
/// </para>
/// </remarks>
public sealed class AiGatewayAvailabilityProjection : IAiGatewayAvailabilitySource
{
    private readonly IAiHealthSnapshotStore _snapshots;
    private readonly AiCapabilityRegister _capabilities;
    private readonly TimeProvider _time;

    /// <summary>Projects availability from the estate's health snapshot and capability register.</summary>
    public AiGatewayAvailabilityProjection(
        IAiHealthSnapshotStore snapshots,
        AiCapabilityRegister capabilities,
        TimeProvider time)
    {
        ArgumentNullException.ThrowIfNull(snapshots);
        ArgumentNullException.ThrowIfNull(capabilities);
        ArgumentNullException.ThrowIfNull(time);

        _snapshots = snapshots;
        _capabilities = capabilities;
        _time = time;
    }

    /// <inheritdoc />
    public AiGatewayAvailability Read()
    {
        var snapshot = _snapshots.Current;
        var (state, reason) = HeadOf(snapshot);

        return new AiGatewayAvailability
        {
            State = state,
            Reason = reason,
            ObservedAt = snapshot.TakenAt == default ? _time.GetUtcNow() : snapshot.TakenAt,

            // Every capability the register knows, with the Head's state as the ceiling. A register
            // that lists a disabled capability still lists it: absent and unavailable are different
            // answers, and the caller that discovers the difference by invoking has already spent a
            // request finding out.
            Capabilities = [.. _capabilities.List().Select(registration => For(registration, state, reason))],
        };
    }

    /// <inheritdoc />
    public AiCapabilityAvailability? Read(CapabilityId capability)
    {
        if (!_capabilities.TryResolve(capability, out var registration) || registration is null)
        {
            // Absent rather than unservable. A caller told "unavailable" for a capability that is not
            // in the register would retry a request that can never succeed; the typed failure for that
            // case is CapabilityNotFound, and it is raised where the capability is actually invoked.
            return null;
        }

        var (state, reason) = HeadOf(_snapshots.Current);

        return For(registration, state, reason);
    }

    /// <summary>An entry's availability, bounded by the Head's own.</summary>
    /// <remarks>
    /// The Head's state is the ceiling, and a capability can only narrow it. A capability cannot be
    /// more available than the estate that would serve it, and the alternative — reporting a disabled
    /// capability as available because the Head is healthy — is the reading that makes a caller
    /// discover the difference by failing.
    /// </remarks>
    private static AiCapabilityAvailability For(
        AiCapabilityRegistration registration,
        AiAvailabilityState headState,
        AiAvailabilityReason headReason) => new()
    {
        Capability = registration.Capability,
        State = registration.Enabled ? headState : AiAvailabilityState.Unavailable,
        Reason = registration.Enabled ? headReason : AiAvailabilityReason.NotConfigured,
    };

    /// <summary>The Head's own state and the provider-neutral reason for it.</summary>
    private static (AiAvailabilityState State, AiAvailabilityReason Reason) HeadOf(AiHealthSnapshot snapshot)
    {
        var states = snapshot.Providers.Values.ToArray();

        // Nothing has been declared and nothing has been probed. See the type's remarks: this is the
        // one reading that is neither of the two convenient ones.
        if (states.Length == 0)
        {
            return (AiAvailabilityState.Unknown, AiAvailabilityReason.HealthUnpublished);
        }

        var usable = states.Count(IsUsable);

        if (usable == 0)
        {
            return (AiAvailabilityState.Unavailable, AiAvailabilityReason.NoUsableRoute);
        }

        // Every provider usable and every one of them serving normally. Rate limited and degraded are
        // usable, so they land in the branch below rather than here.
        if (usable == states.Length && states.All(state => state is AiModelHealthState.Available))
        {
            return (AiAvailabilityState.Available, AiAvailabilityReason.None);
        }

        return (AiAvailabilityState.Degraded, AiAvailabilityReason.ReducedRedundancy);
    }

    /// <summary>True when a provider in this state can still serve a request.</summary>
    /// <remarks>
    /// <see cref="AiModelHealthState.RateLimited"/> and <see cref="AiModelHealthState.Degraded"/> are
    /// usable on purpose: the router ranks them below a healthy route and does not refuse them, so a
    /// projection that called them unavailable would take callers off the AI path at exactly the
    /// moment the estate was still able to serve them.
    /// </remarks>
    private static bool IsUsable(AiModelHealthState state)
        => state is AiModelHealthState.Available
            or AiModelHealthState.RateLimited
            or AiModelHealthState.Degraded;
}
