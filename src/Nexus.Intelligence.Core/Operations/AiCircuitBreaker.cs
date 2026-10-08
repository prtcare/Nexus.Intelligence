using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// Answers what a route's circuit state is, from the history the estate already keeps.
/// </summary>
/// <remarks>
/// <b>Synchronous, and it exists so that routing never has to block or wait.</b> A breaker that
/// decided its state at the moment of a call would have to be consulted from inside the routing
/// decision, which is the inline probing the architecture forbids. This one answers a question about
/// the past, and the routing decision does whatever the answer says.
/// </remarks>
public interface IAiCircuitBreaker
{
    /// <summary>
    /// The circuit state for one route at an instant. Never null; an unobserved route is healthy.
    /// </summary>
    AiCircuitSnapshot For(string providerId, string modelId, DateTimeOffset now);
}

/// <summary>
/// The circuit, reconstructed from the attempt history rather than stored beside it.
/// </summary>
/// <remarks>
/// <para>
/// <b>There is no circuit object.</b> The state is a pure function of the recorded attempts, the
/// configured opening conditions and the instant it is asked about. The consequences are the reason
/// it is built this way rather than as a mutable state machine:
/// </para>
/// <list type="bullet">
/// <item>
/// <b>Nothing can be lost.</b> A stored circuit has a transition to write and a crash between two
/// writes to survive; a derived one has neither. Restarting the process cannot leave a route
/// permanently open, because there is nothing persisted to be stale.
/// </item>
/// <item>
/// <b>Nothing is deleted to recover.</b> Recovery is a new fact at the end of the history, not the
/// removal of old facts. The failures that opened the circuit are still there afterwards, which is
/// what lets the snapshot report them alongside a recovered state.
/// </item>
/// <item>
/// <b>The cooldown is honest.</b> Because the opening instant is read back out of the history rather
/// than held in a field, it cannot be accidentally reset by a caller, a retry or a restart. A
/// cooldown that quietly restarts is a latch with extra steps.
/// </item>
/// <item>
/// <b>Two readers cannot disagree.</b> Routing reads a snapshot, the operations endpoint reads a
/// snapshot, and the audit record carries one — all derived from the same attempts by the same
/// function, rather than from a shared mutable object at three different moments.
/// </item>
/// </list>
/// <para>
/// <b>Concurrency, stated plainly.</b> The bound on probe traffic is a bound on the evidence the
/// estate has: routing will not permit a probe it can see has already been spent. Two requests
/// arriving in the same instant, before either has recorded its attempt, can both be permitted. The
/// budget gate has exactly the same property for exactly the same reason — it is evaluated against
/// committed spend, and spend is committed after the call. The estate's consistency model is
/// evidence-after-the-fact throughout, and this is consistent with it rather than exempt from it.
/// </para>
/// </remarks>
public sealed class ReplayedAiCircuitBreaker : IAiCircuitBreaker
{
    private readonly IAiReliabilityHistory _history;
    private readonly AiReliabilityPolicy _reliability;
    private readonly AiCircuitPolicy _circuit;

    /// <summary>Builds the breaker over a history and the two policies that shape it.</summary>
    public ReplayedAiCircuitBreaker(
        IAiReliabilityHistory history,
        AiReliabilityPolicy reliabilityPolicy,
        AiCircuitPolicy circuitPolicy)
    {
        ArgumentNullException.ThrowIfNull(history);
        ArgumentNullException.ThrowIfNull(reliabilityPolicy);
        ArgumentNullException.ThrowIfNull(circuitPolicy);

        reliabilityPolicy.Validate();
        circuitPolicy.Validate();

        _history = history;
        _reliability = reliabilityPolicy;
        _circuit = circuitPolicy;
    }

    /// <inheritdoc />
    public AiCircuitSnapshot For(string providerId, string modelId, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(providerId);
        ArgumentNullException.ThrowIfNull(modelId);

        if (!_circuit.Enabled)
        {
            return Healthy(
                providerId,
                modelId,
                now,
                AiCircuitStateChangeReason.None,
                "The recovery model is not applied by configuration, so this route has no circuit state. "
                + "A route refused under this posture is refused by the reliability gate for the lifetime "
                + "of the process, which is the estate's behaviour before the recovery model existed.");
        }

        if (!_reliability.Enabled)
        {
            return Healthy(
                providerId,
                modelId,
                now,
                AiCircuitStateChangeReason.None,
                "The reliability plane is not evaluated by configuration, so no circuit can open: a "
                + "circuit is opened by observed behaviour and nothing is observing it.");
        }

        var attempts = _history.AttemptsFor(providerId, modelId);

        if (attempts.Count == 0)
        {
            return Healthy(
                providerId,
                modelId,
                now,
                AiCircuitStateChangeReason.None,
                $"No attempt has been observed for model '{modelId}' on provider '{providerId}'. A route "
                + "with no evidence is unobserved, not suspect; requiring evidence is a separate and "
                + "explicit policy.");
        }

        var state = AiCircuitState.Healthy;
        var reason = AiCircuitStateChangeReason.None;
        DateTimeOffset? openedAt = null;

        var consecutiveFailures = 0;
        var probeAttempts = 0;
        var probeSuccesses = 0;
        var observed = 0;
        var succeeded = 0;

        foreach (var attempt in attempts)
        {
            observed++;
            if (attempt.Succeeded)
            {
                succeeded++;
            }

            // The cooldown is a fact about elapsed time, so it is resolved before the attempt is
            // applied: an attempt that arrives after the cooldown is the probe, not more evidence
            // about the outage that the circuit already decided to stop collecting.
            if (state is AiCircuitState.Open
                && openedAt is { } since
                && attempt.At - since >= _circuit.Cooldown)
            {
                state = AiCircuitState.HalfOpen;
                reason = AiCircuitStateChangeReason.CooldownElapsed;
                consecutiveFailures = 0;
                probeAttempts = 0;
                probeSuccesses = 0;
            }

            switch (state)
            {
                case AiCircuitState.Healthy:
                case AiCircuitState.Degraded:
                    if (attempt.Succeeded)
                    {
                        consecutiveFailures = 0;

                        if (state is AiCircuitState.Degraded)
                        {
                            state = AiCircuitState.Healthy;
                            reason = AiCircuitStateChangeReason.FailureRunBroken;
                        }
                    }
                    else
                    {
                        consecutiveFailures++;
                    }

                    // The two opening conditions, evaluated in the reliability gate's own order and
                    // against its own members. The ceiling is checked first because it is a current
                    // signal: a route that has just failed three times in a row is better described by
                    // that than by a rate diluted over a week of earlier successes. The rate is checked
                    // on every attempt rather than only on failures, because the sample size that makes
                    // a rate meaningful grows on a success too.
                    if (consecutiveFailures >= _reliability.ConsecutiveFailureCeiling)
                    {
                        state = AiCircuitState.Open;
                        reason = AiCircuitStateChangeReason.ConsecutiveFailureCeilingReached;
                        openedAt = attempt.At;
                        probeAttempts = 0;
                        probeSuccesses = 0;
                    }
                    else if (RateBelowFloor(observed, succeeded))
                    {
                        state = AiCircuitState.Open;
                        reason = AiCircuitStateChangeReason.SuccessRateBelowFloor;
                        openedAt = attempt.At;
                        probeAttempts = 0;
                        probeSuccesses = 0;
                    }
                    else if (!attempt.Succeeded)
                    {
                        state = AiCircuitState.Degraded;
                        reason = AiCircuitStateChangeReason.FailureObserved;
                    }

                    break;

                case AiCircuitState.HalfOpen:
                case AiCircuitState.Recovering:
                    probeAttempts++;

                    if (!attempt.Succeeded)
                    {
                        // A failed probe reopens and restarts the cooldown from the probe's own
                        // instant. The route has told the estate something new, and the estate waits
                        // again from when it was told.
                        state = AiCircuitState.Open;
                        reason = AiCircuitStateChangeReason.ProbeFailed;
                        openedAt = attempt.At;
                        probeAttempts = 0;
                        probeSuccesses = 0;
                        consecutiveFailures = 0;
                    }
                    else if (++probeSuccesses >= _circuit.ProbeSuccessesRequired)
                    {
                        state = AiCircuitState.Healthy;
                        reason = AiCircuitStateChangeReason.RecoveryCompleted;
                        openedAt = null;
                        probeAttempts = 0;
                        probeSuccesses = 0;
                        consecutiveFailures = 0;
                    }
                    else
                    {
                        state = AiCircuitState.Recovering;
                        reason = AiCircuitStateChangeReason.ProbeSucceeded;
                    }

                    break;

                case AiCircuitState.Open:
                    // An attempt observed while the circuit is open and the cooldown has not yet
                    // elapsed. Routing refuses this route, so in the steady state this is work that
                    // was already in flight when the circuit opened. It is kept — it is evidence of
                    // what the provider did — but it does not move OpenedAt. A cooldown that restarted
                    // on every attempt would never elapse on a route under load, and the route would
                    // be refused forever while every recorded fact said the cooldown was running.
                    break;
            }
        }

        // The cooldown may have elapsed since the last attempt, with nothing in between to observe.
        // This is the ordinary case: a circuit opens, the estate stops calling, time passes.
        if (state is AiCircuitState.Open
            && openedAt is { } opened
            && now - opened >= _circuit.Cooldown)
        {
            state = AiCircuitState.HalfOpen;
            reason = AiCircuitStateChangeReason.CooldownElapsed;
            probeAttempts = 0;
            probeSuccesses = 0;
        }

        var failures = attempts.Where(attempt => !attempt.Succeeded).ToArray();
        var lastFailure = failures.Length == 0 ? null : failures[^1];

        return new AiCircuitSnapshot
        {
            ProviderId = providerId,
            ModelId = modelId,
            State = state,
            Reason = reason,
            EvaluatedAt = now,
            OpenedAt = openedAt,
            CooldownElapsedAt = openedAt is { } from ? from + _circuit.Cooldown : null,
            ProbeAttempts = probeAttempts,
            ProbeSuccesses = probeSuccesses,
            ProbeAllowance = _circuit.ProbeAllowance,
            AttemptsObserved = observed,
            FailuresObserved = observed - succeeded,
            LastFailureAt = lastFailure?.At,
            LastFailureCategory = lastFailure?.FailureCategory,
            Detail = Describe(state, reason, openedAt, now, probeAttempts, observed, observed - succeeded),
        };
    }

    /// <summary>
    /// Whether the observed record has fallen below the configured success-rate floor.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>The same two members the reliability gate reads, and deliberately not a second copy of
    /// them.</b> <see cref="AiReliabilityPolicy.MinimumSampleSize"/> and
    /// <see cref="AiReliabilityPolicy.MinimumSuccessRate"/> are the estate's statement of when a rate
    /// is worth acting on and how low is too low; a circuit that carried its own pair would be a second
    /// place for an operator to change one threshold and a first place for the two to disagree.
    /// </para>
    /// <para>
    /// The sample-size floor is the part that matters here. Without it, a route that failed its first
    /// call and succeeded its second would be judged at a rate of one half and stopped — which is the
    /// estate's newest capacity being refused on the strength of having been tried once.
    /// </para>
    /// </remarks>
    private bool RateBelowFloor(int observed, int succeeded)
        => observed >= _reliability.MinimumSampleSize
            && (double)succeeded / observed < _reliability.MinimumSuccessRate;

    /// <summary>The opening condition, in words, for the snapshot's detail.</summary>
    /// <remarks>
    /// Named rather than left to the <see cref="AiCircuitSnapshot.Reason"/> member alone, because the
    /// detail is what an operator reads first and "the route is refused" without a condition is the
    /// sentence that sends them looking for a cause that the same record already carries.
    /// </remarks>
    private static string Opening(AiCircuitStateChangeReason reason) => reason switch
    {
        AiCircuitStateChangeReason.ConsecutiveFailureCeilingReached =>
            "it failed the configured number of consecutive attempts.",

        AiCircuitStateChangeReason.SuccessRateBelowFloor =>
            "its observed success rate is below the configured floor on a sample large enough to judge.",

        AiCircuitStateChangeReason.ProbeFailed =>
            "a probationary probe failed, so the estate has waited again from that probe.",

        _ => "it was stopped by the configured opening conditions.",
    };

    private AiCircuitSnapshot Healthy(
        string providerId,
        string modelId,
        DateTimeOffset now,
        AiCircuitStateChangeReason reason,
        string detail) => new()
        {
            ProviderId = providerId,
            ModelId = modelId,
            State = AiCircuitState.Healthy,
            Reason = reason,
            EvaluatedAt = now,
            ProbeAllowance = _circuit.ProbeAllowance,
            Detail = detail,
        };

    /// <summary>
    /// The state in words, for an operator and for the audit record.
    /// </summary>
    /// <remarks>
    /// Written from the state rather than stored with it, so the sentence cannot drift away from the
    /// value it describes — which is the failure mode of a message field that is set at one call site
    /// and a state that is set at another.
    /// </remarks>
    private string Describe(
        AiCircuitState state,
        AiCircuitStateChangeReason reason,
        DateTimeOffset? openedAt,
        DateTimeOffset now,
        int probeAttempts,
        int observed,
        int failures)
    {
        var history = $"{observed} attempt(s) observed, {failures} failed; failure history retained.";

        return state switch
        {
            AiCircuitState.Healthy when reason is AiCircuitStateChangeReason.RecoveryCompleted =>
                $"The route recovered: {_circuit.ProbeSuccessesRequired} probe(s) succeeded after the "
                + $"cooldown. It is eligible for ordinary traffic again. {history}",

            AiCircuitState.Healthy when reason is AiCircuitStateChangeReason.FailureRunBroken =>
                $"The route was degraded and a success ended the failure run before the ceiling was "
                + $"reached. {history}",

            AiCircuitState.Healthy => $"The route is serving normally. {history}",

            AiCircuitState.Degraded =>
                $"Failures are accumulating below the configured opening conditions, so the route is "
                + $"still eligible. {history}",

            AiCircuitState.Open when openedAt is { } opened =>
                $"The route is refused because {Opening(reason)} Its circuit opened at {opened:O} and "
                + $"its cooldown of {_circuit.Cooldown} elapses at {opened + _circuit.Cooldown:O}; "
                + $"{Remaining(opened, now)} remain. Probes are not yet permitted. {history}",

            AiCircuitState.HalfOpen =>
                $"The route's cooldown has elapsed. It is eligible for probe traffic only, up to "
                + $"{_circuit.ProbeAllowance - probeAttempts} more call(s); {probeAttempts} probe(s) have "
                + $"been made since it opened. Ordinary traffic is refused. {history}",

            AiCircuitState.Recovering =>
                $"The route's probes are succeeding: {probeAttempts} made, "
                + $"{_circuit.ProbeSuccessesRequired} required to recover fully. It remains probe-only "
                + $"until then, and ordinary traffic is refused. {history}",

            _ => history,
        };
    }

    private string Remaining(DateTimeOffset opened, DateTimeOffset now)
    {
        var left = (opened + _circuit.Cooldown) - now;
        return left > TimeSpan.Zero ? left.ToString() : "no time";
    }
}
