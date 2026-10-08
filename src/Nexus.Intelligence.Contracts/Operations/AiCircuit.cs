namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The probation state of one route, as the operational stage understands it.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the release path for a route the reliability gate has refused.</b> The reliability
/// gate answers "is this route's observed behaviour good enough"; on its own that answer is
/// permanent, because the only writer of observed behaviour is a provider invocation and a refused
/// route is never invoked. The circuit adds the missing half: a route that has failed badly enough
/// stops being asked, and is then asked again — a little, later, under supervision.
/// </para>
/// <para>
/// <b>Historical failures are never discarded to achieve this.</b> Every member here is derived by
/// reading the attempt history that the reliability plane already keeps; nothing is deleted,
/// overwritten or reset, and a route that recovers still reports the failures that opened its
/// circuit. Recovery is a state transition, not a memory hole.
/// </para>
/// <para>
/// <b>Do not confuse <see cref="Degraded"/> here with <see cref="AiModelHealthState.Degraded"/>.</b>
/// They are different facts about different things. The health member means "reachable and serving,
/// but slower or throttled than normal" and is declared by configuration or a probe. This one means
/// "failures are accumulating against this route and it has not been asked to stop yet" and is
/// derived from observed attempts. A route can be health-<c>Available</c> and circuit-<c>Degraded</c>
/// at the same time, and that is the normal state of a provider having a bad afternoon.
/// </para>
/// </remarks>
public enum AiCircuitState
{
    /// <summary>Serving normally. Nothing about observed behaviour says otherwise.</summary>
    /// <remarks>
    /// Also the state of a route with no observations at all. An unobserved route is not a suspect
    /// one: <see cref="AiReliabilityPolicy.RequireEvidence"/> is the member that expresses the
    /// opposite opinion, and it does so explicitly.
    /// </remarks>
    Healthy = 0,

    /// <summary>Failures are accumulating, below the configured opening conditions. Still eligible.</summary>
    Degraded = 1,

    /// <summary>Open. Routing refuses this route outright until its cooldown has elapsed.</summary>
    /// <remarks>
    /// The refusal is not a judgement about the provider's current health — the estate may have no
    /// health signal at all. It is a statement that the estate has decided not to spend further
    /// calls on this route until it has waited.
    /// </remarks>
    Open = 2,

    /// <summary>The cooldown has elapsed. Bounded probe traffic is permitted; ordinary traffic is not.</summary>
    HalfOpen = 3,

    /// <summary>Probes are succeeding, but not yet enough of them to declare the route recovered.</summary>
    /// <remarks>
    /// Distinct from <see cref="HalfOpen"/> because the two say different things to an operator:
    /// half-open is "we have not tried yet", recovering is "we have tried and it worked, once". A
    /// route in this state is still probe-only.
    /// </remarks>
    Recovering = 4,
}

/// <summary>Why a route's circuit is in the state it is in.</summary>
/// <remarks>
/// A state without a reason is not an operational fact. <see cref="AiCircuitState.Open"/> reached
/// because three calls failed in a row and <see cref="AiCircuitState.Open"/> reached because a probe
/// failed are the same state and call for different responses, and an operator reading only the
/// state cannot tell them apart.
/// </remarks>
public enum AiCircuitStateChangeReason
{
    /// <summary>Nothing has been observed, so nothing has changed. Accompanies a healthy route.</summary>
    None = 0,

    /// <summary>A failure was observed. The route moved to <see cref="AiCircuitState.Degraded"/>.</summary>
    FailureObserved = 1,

    /// <summary>
    /// Consecutive failures reached the configured ceiling. The circuit opened.
    /// </summary>
    ConsecutiveFailureCeilingReached = 2,

    /// <summary>
    /// The observed success rate fell below the configured floor on a sufficient sample. The circuit
    /// opened.
    /// </summary>
    SuccessRateBelowFloor = 3,

    /// <summary>
    /// A success was observed where the route had been degraded, and the route returned to
    /// <see cref="AiCircuitState.Healthy"/> without ever opening.
    /// </summary>
    FailureRunBroken = 4,

    /// <summary>The configured cooldown elapsed. The circuit moved to <see cref="AiCircuitState.HalfOpen"/>.</summary>
    CooldownElapsed = 5,

    /// <summary>A probe succeeded but the configured requirement is not yet met.</summary>
    ProbeSucceeded = 6,

    /// <summary>A probe failed. The circuit reopened from <see cref="AiCircuitState.HalfOpen"/>.</summary>
    ProbeFailed = 7,

    /// <summary>The configured number of probes succeeded. The route is fully eligible again.</summary>
    RecoveryCompleted = 8,
}

/// <summary>
/// How long a refused route stays refused, and how much traffic it may be given to prove itself.
/// </summary>
/// <remarks>
/// <para>
/// <b>This policy owns the release, not the refusal.</b> The conditions that open a circuit are the
/// ones the reliability plane already carries — <see cref="AiReliabilityPolicy.MinimumSampleSize"/>,
/// <see cref="AiReliabilityPolicy.MinimumSuccessRate"/> and
/// <see cref="AiReliabilityPolicy.ConsecutiveFailureCeiling"/>. They are deliberately not restated
/// here. Two copies of one threshold is two places for an operator to change it and one of them to
/// be wrong.
/// </para>
/// <para>
/// <b>Nothing here is a fixed production threshold.</b> Every member is configurable and every
/// member's default is stated with the reason it holds that value, so an operator changing one is
/// changing a decision rather than discovering a constant.
/// </para>
/// </remarks>
public sealed record AiCircuitPolicy
{
    /// <summary>Whether the recovery model is applied at all.</summary>
    /// <remarks>
    /// <b>Disabling this restores the pre-W7G-R behaviour exactly:</b> a route refused by the
    /// reliability gate stays refused for the process lifetime. That is kept as a supported posture
    /// rather than deleted, because an estate that has not decided its cooldown should be able to say
    /// so, and because the contrast is what makes the recovery model's effect measurable.
    /// </remarks>
    public bool Enabled { get; init; } = true;

    /// <summary>How long a route stays <see cref="AiCircuitState.Open"/> before it may be probed.</summary>
    /// <remarks>
    /// <para>
    /// <b>One minute by default, and that number is borrowed rather than invented.</b> The estate
    /// already ships <c>Ai:Operations:Health:IntervalSeconds</c> at 60, the cadence at which it would
    /// look at a provider's health were probing composed. A cooldown of the same length means a route
    /// is offered its first probe on the same rhythm the estate uses to ask about anything else,
    /// instead of on a second rhythm an operator has to hold in their head.
    /// </para>
    /// <para>
    /// The requirement this member has to satisfy is a floor, not a target: it must be long enough
    /// that an immediate retry is still refused. Any positive value does that for a retry that
    /// carries no delay, which is why the interesting part of the choice is operational fit rather
    /// than a magic number.
    /// </para>
    /// </remarks>
    public TimeSpan Cooldown { get; init; } = TimeSpan.FromMinutes(1);

    /// <summary>How many calls a half-open route may be given before it is judged again.</summary>
    /// <remarks>
    /// One, by default. A circuit that is half-open is asking a question, and one call answers it
    /// when the answer is a failure. Raising this lets a transient blip be survived; it also lets a
    /// broken provider absorb more real traffic before the estate reacts, so it is raised knowingly
    /// rather than by default.
    /// </remarks>
    public int ProbeAllowance { get; init; } = 1;

    /// <summary>How many of those probes must succeed before the route is fully eligible again.</summary>
    /// <remarks>
    /// One, by default, and it may never exceed <see cref="ProbeAllowance"/> — a requirement for more
    /// successes than there are attempts could never be met, which would leave a route permanently
    /// probe-only while reading as a recovery policy. That invariant is enforced by
    /// <see cref="Validate"/> rather than left to arithmetic to discover.
    /// </remarks>
    public int ProbeSuccessesRequired { get; init; } = 1;

    /// <summary>The shipped policy: recovery applied, one minute, one probe, one success.</summary>
    public static AiCircuitPolicy Default { get; } = new();

    /// <summary>
    /// No recovery. A refused route stays refused, which is what the estate did before this policy
    /// existed.
    /// </summary>
    public static AiCircuitPolicy NotEvaluated { get; } = new() { Enabled = false };

    /// <summary>Validates the policy, throwing on the first defect.</summary>
    /// <exception cref="ArgumentException">A value is outside its meaningful range.</exception>
    public void Validate()
    {
        if (Cooldown <= TimeSpan.Zero)
        {
            throw new ArgumentException(
                "The cooldown is not positive. A circuit whose cooldown has already elapsed when it opens "
                + "is a circuit that never asks the provider to stop, and the refusal it produces is "
                + "indistinguishable from a route that was never refused.",
                nameof(Cooldown));
        }

        if (ProbeAllowance < 1)
        {
            throw new ArgumentException(
                "The probe allowance is below one. A half-open circuit with no probes permitted can never "
                + "learn anything, so it can never close: the route would stay refused for the process "
                + "lifetime while presenting itself as recoverable.",
                nameof(ProbeAllowance));
        }

        if (ProbeSuccessesRequired < 1)
        {
            throw new ArgumentException(
                "The required probe successes is below one. A route would recover on the strength of "
                + "having been asked, which is not evidence that anything works.",
                nameof(ProbeSuccessesRequired));
        }

        if (ProbeSuccessesRequired > ProbeAllowance)
        {
            throw new ArgumentException(
                $"The policy requires {ProbeSuccessesRequired} successful probe(s) from an allowance of "
                + $"{ProbeAllowance}. The requirement can never be met, so the route would stay in probation "
                + "permanently — the very failure this policy exists to remove, wearing the vocabulary of "
                + "recovery.",
                nameof(ProbeSuccessesRequired));
        }
    }
}

/// <summary>
/// The circuit's state for one route, with the facts behind the state and the facts that would
/// change it.
/// </summary>
/// <remarks>
/// <para>
/// <b>It is derived, not stored.</b> Every member is a function of the recorded attempts and the
/// configured policy, computed when it is asked for. There is no mutable circuit object to keep in
/// step with the history, no transition that can be lost to a crash between two writes, and no way
/// for routing to observe a state that changed halfway through a decision.
/// </para>
/// <para>
/// <b>It carries no identifier of any kind, and no free text from a provider.</b> The attempt history
/// it is derived from carries a failure <em>category</em> — a member of a closed vocabulary — and
/// never a provider's own error string, so nothing on this path can carry vendor text to a caller.
/// </para>
/// </remarks>
public sealed record AiCircuitSnapshot
{
    /// <summary>The provider this state is about.</summary>
    public required string ProviderId { get; init; }

    /// <summary>The model this state is about.</summary>
    public required string ModelId { get; init; }

    /// <summary>The state.</summary>
    public required AiCircuitState State { get; init; }

    /// <summary>Why it is in that state.</summary>
    public required AiCircuitStateChangeReason Reason { get; init; }

    /// <summary>The instant the state was derived for.</summary>
    public required DateTimeOffset EvaluatedAt { get; init; }

    /// <summary>When the circuit most recently opened, if it has.</summary>
    /// <remarks>
    /// Measured from the failure that opened it and <b>not</b> moved by anything that happens while
    /// the circuit is open. A cooldown that restarted on every attempt would never elapse for a route
    /// under load, which is a latch wearing different clothes.
    /// </remarks>
    public DateTimeOffset? OpenedAt { get; init; }

    /// <summary>When the cooldown ends and a probe becomes possible.</summary>
    public DateTimeOffset? CooldownElapsedAt { get; init; }

    /// <summary>Whether the cooldown has elapsed at <see cref="EvaluatedAt"/>.</summary>
    /// <remarks>
    /// False for a route that has never opened, because <see cref="CooldownElapsedAt"/> is null there.
    /// A healthy route is not "past its cooldown"; it has never had one, and answering true would let
    /// a caller read a healthy route as one that had recovered.
    /// </remarks>
    public bool CooldownElapsed => CooldownElapsedAt is { } until && EvaluatedAt >= until;

    /// <summary>How many calls have been made since the circuit opened.</summary>
    public int ProbeAttempts { get; init; }

    /// <summary>How many of those succeeded.</summary>
    public int ProbeSuccesses { get; init; }

    /// <summary>The configured allowance for this opening.</summary>
    public int ProbeAllowance { get; init; }

    /// <summary>How many permitted probes remain.</summary>
    public int ProbeAllowanceRemaining =>
        State is AiCircuitState.HalfOpen or AiCircuitState.Recovering
            ? Math.Max(0, ProbeAllowance - ProbeAttempts)
            : 0;

    /// <summary>Whether ordinary, caller-driven traffic may use this route.</summary>
    public bool IsEligible =>
        State is AiCircuitState.Healthy or AiCircuitState.Degraded;

    /// <summary>Whether routing may send a bounded probe call to this route.</summary>
    public bool IsProbePermitted =>
        State is AiCircuitState.HalfOpen or AiCircuitState.Recovering && ProbeAllowanceRemaining > 0;

    /// <summary>Every attempt ever observed for this route within the retained window.</summary>
    /// <remarks>
    /// Reported on the snapshot rather than left in the history so that "the failures are still
    /// recorded" is a fact an operator can read from the same record that tells them the route has
    /// recovered. A recovery that only reported the new state would be indistinguishable from one
    /// that had deleted the old one.
    /// </remarks>
    public int AttemptsObserved { get; init; }

    /// <summary>How many of those failed.</summary>
    public int FailuresObserved { get; init; }

    /// <summary>The most recent failure, if any was observed.</summary>
    public DateTimeOffset? LastFailureAt { get; init; }

    /// <summary>What the failure was, in the closed vocabulary. Never a provider's own text.</summary>
    public AiFailureCategory? LastFailureCategory { get; init; }

    /// <summary>Why the state is what it is, in the estate's own words.</summary>
    public required string Detail { get; init; }
}
