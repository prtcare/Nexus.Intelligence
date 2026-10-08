namespace Nexus.Intelligence.Contracts;

/// <summary>
/// One attempt's outcome, as the reliability history records it.
/// </summary>
/// <remarks>
/// <para>
/// <b>Recorded after the fact and never consulted during the attempt it describes.</b> An attempt
/// that read the history it was about to be written into would make the history's contents depend on
/// the order attempts happened to run in, and a replay would not reproduce it.
/// </para>
/// <para>
/// <see cref="FailureCategory"/> distinguishes a provider fault from a model fault, which is the
/// estate's existing taxonomy and the reason a provider outage does not reduce a model's quality
/// score. The category is carried per attempt rather than summarised, so the recent-failure
/// question can be answered without re-deriving it.
/// </para>
/// </remarks>
public sealed record AiReliabilityAttempt
{
    /// <summary>The provider the attempt used.</summary>
    public required string ProviderId { get; init; }

    /// <summary>The model the attempt used.</summary>
    public required string ModelId { get; init; }

    /// <summary>True when the attempt produced a usable result.</summary>
    public required bool Succeeded { get; init; }

    /// <summary>The failure category, present exactly when the attempt failed.</summary>
    public AiFailureCategory? FailureCategory { get; init; }

    /// <summary>How long the attempt took, where it was measured.</summary>
    public TimeSpan? Latency { get; init; }

    /// <summary>True when the attempt was a fallback rather than the primary route.</summary>
    public bool IsFallback { get; init; }

    /// <summary>When the attempt finished.</summary>
    public required DateTimeOffset At { get; init; }
}

/// <summary>
/// What the estate has observed about one model on one provider.
/// </summary>
/// <remarks>
/// <para>
/// <b>Evidence, not a configured guess.</b> Before this type the only thing the router called
/// "reliability" was the provider's trust tier — a governance classification an operator writes,
/// which says what the provider is <em>permitted</em> to be trusted with and nothing about whether
/// it has been working. The two are different questions and the router was answering one while
/// being read as answering the other.
/// </para>
/// <para>
/// <b><see cref="SuccessRate"/> is null when nothing has been observed, and null is not zero.</b>
/// A rate over zero attempts is undefined; reporting it as zero would make a brand new route look
/// like a failing one, and the estate would refuse its newest capacity until it had been used.
/// </para>
/// </remarks>
public sealed record AiReliabilityEvidence
{
    /// <summary>The provider.</summary>
    public required string ProviderId { get; init; }

    /// <summary>The model.</summary>
    public required string ModelId { get; init; }

    /// <summary>How many attempts have been observed.</summary>
    public required int Attempts { get; init; }

    /// <summary>How many succeeded.</summary>
    public required int Successes { get; init; }

    /// <summary>How many failed. Derived, so it cannot disagree with its parts.</summary>
    public int Failures => Attempts - Successes;

    /// <summary>How many fallback attempts were observed.</summary>
    public int FallbackAttempts { get; init; }

    /// <summary>The most recent failure's category, or null when nothing has failed.</summary>
    public AiFailureCategory? LastFailureCategory { get; init; }

    /// <summary>How many attempts have failed consecutively, most recent first.</summary>
    public int ConsecutiveFailures { get; init; }

    /// <summary>Where the most recent failure happened, or null when nothing has failed.</summary>
    public DateTimeOffset? LastFailureAt { get; init; }

    /// <summary>When the most recent attempt finished. Null when nothing has been observed.</summary>
    public DateTimeOffset? LastAttemptAt { get; init; }

    /// <summary>Mean observed latency, or null when none was measured.</summary>
    public TimeSpan? AverageLatency { get; init; }

    /// <summary>The observed success rate, or null when nothing has been observed.</summary>
    /// <remarks>
    /// Null and not zero, deliberately: an unobserved route is not a failing route.
    /// </remarks>
    public double? SuccessRate => Attempts == 0 ? null : (double)Successes / Attempts;

    /// <summary>True when this evidence rests on enough attempts to be worth acting on.</summary>
    public bool HasSample(int minimumAttempts) => Attempts >= minimumAttempts;

    /// <summary>Nothing observed. The state every route starts in.</summary>
    public static AiReliabilityEvidence None(string providerId, string modelId) => new()
    {
        ProviderId = providerId,
        ModelId = modelId,
        Attempts = 0,
        Successes = 0,
    };
}

/// <summary>
/// The thresholds that turn observed evidence into a routing refusal.
/// </summary>
/// <remarks>
/// <para>
/// <b>Every threshold is a configuration value, and none of them is a number in the router.</b> The
/// directive is explicit that arbitrary reliability thresholds must not be hardcoded, and the reason
/// is operational: the right floor for a batch summarisation route and the right floor for an
/// interactive coding route are different numbers owned by different people.
/// </para>
/// <para>
/// <b><see cref="RequireEvidence"/> defaults to false, and that default is deliberate.</b> An estate
/// with no history refuses nothing on reliability grounds; the gate tightens as evidence accumulates
/// rather than refusing everything until it does. An estate that wants the stricter posture sets it
/// true, and then a route with an insufficient sample is refused with
/// <see cref="AiRoutingRejectionReason.ReliabilityEvidenceMissing"/> rather than
/// <see cref="AiRoutingRejectionReason.ReliabilityTooLow"/> — "we do not know" and "we know it is
/// bad" are different findings and the vocabulary keeps them apart.
/// </para>
/// </remarks>
public sealed record AiReliabilityPolicy
{
    /// <summary>Whether the reliability gate is applied at all.</summary>
    public bool Enabled { get; init; } = true;

    /// <summary>The minimum attempts before <see cref="MinimumSuccessRate"/> is applied.</summary>
    /// <remarks>
    /// Below this many attempts the rate is not consulted. Three attempts is one bad afternoon, not
    /// a reliability finding, and gating on it would make the estate route away from capacity on the
    /// strength of a coincidence.
    /// </remarks>
    public int MinimumSampleSize { get; init; } = 5;

    /// <summary>The success rate below which a sufficiently sampled route is refused.</summary>
    public double MinimumSuccessRate { get; init; } = 0.5;

    /// <summary>The consecutive-failure count at which a route is refused regardless of sample size.</summary>
    /// <remarks>
    /// A consecutive-failure run is actionable before the sample is large, because it is a current
    /// signal rather than a historic rate — a provider that has just failed three times in a row is
    /// more usefully described by that than by a rate diluted over a week.
    /// </remarks>
    public int ConsecutiveFailureCeiling { get; init; } = 3;

    /// <summary>Whether evidence is required before a route may be used.</summary>
    public bool RequireEvidence { get; init; }

    /// <summary>How long an observation remains current. Older evidence is reported as stale.</summary>
    public TimeSpan EvidenceLifetime { get; init; } = TimeSpan.FromHours(24);

    /// <summary>The shipped policy: applied, evidence-gated only once there is evidence.</summary>
    public static AiReliabilityPolicy Default { get; } = new();

    /// <summary>The gate is not applied. An explicit posture, not a default.</summary>
    public static AiReliabilityPolicy NotEvaluated { get; } = new() { Enabled = false };

    /// <summary>Validates the policy, throwing on the first defect.</summary>
    /// <exception cref="ArgumentException">A threshold is outside its meaningful range.</exception>
    public void Validate()
    {
        if (MinimumSampleSize < 0)
        {
            throw new ArgumentException(
                "The minimum sample size is negative. A negative sample requirement is not a stricter " +
                "policy, it is arithmetic that cannot be satisfied by any number of attempts.",
                nameof(MinimumSampleSize));
        }

        if (MinimumSuccessRate is < 0d or > 1d)
        {
            throw new ArgumentException(
                $"The minimum success rate is {MinimumSuccessRate}, which is outside 0..1. A rate is a " +
                "proportion; a value outside that range compares against nothing and silently permits or " +
                "refuses every route.",
                nameof(MinimumSuccessRate));
        }

        if (ConsecutiveFailureCeiling < 1)
        {
            throw new ArgumentException(
                "The consecutive-failure ceiling is below one. A ceiling of zero would refuse every route " +
                "that has ever failed, including one that has since succeeded every time.",
                nameof(ConsecutiveFailureCeiling));
        }

        if (EvidenceLifetime <= TimeSpan.Zero)
        {
            throw new ArgumentException(
                "The evidence lifetime is not positive. Evidence that expires immediately is evidence that " +
                "can never be used, which reads as a gate and behaves as a permanent refusal.",
                nameof(EvidenceLifetime));
        }
    }
}

/// <summary>
/// What the estate has observed about its routes.
/// </summary>
/// <remarks>
/// <b>Reads are synchronous and total.</b> A route nobody has observed answers with
/// <see cref="AiReliabilityEvidence.None"/> rather than throwing or returning null, because "we have
/// no evidence about this route" is a legitimate and common answer that the gate has to be able to
/// reason about.
/// </remarks>
public interface IAiReliabilityHistory
{
    /// <summary>Records one attempt's outcome. Called once per provider invocation.</summary>
    void Record(AiReliabilityAttempt attempt);

    /// <summary>The evidence for one route. Never null; an unobserved route answers with no evidence.</summary>
    AiReliabilityEvidence EvidenceFor(string providerId, string modelId);

    /// <summary>
    /// The individual attempts observed for one route, oldest first. Empty for an unobserved route.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Added for the circuit, and it is the reason the circuit needs no state of its own.</b>
    /// <see cref="AiReliabilityEvidence"/> is an aggregate, and an aggregate cannot answer the
    /// question a circuit asks — <em>when</em> did this route's failures happen, and what has
    /// happened since. A success rate of one half describes a route that failed everything and then
    /// recovered, and a route that is failing right now, identically.
    /// </para>
    /// <para>
    /// This exposes observations the history already holds, in the order it already holds them. It
    /// is a read, not a new store: nothing here can record, amend or remove an attempt, so the
    /// guarantee that historical failures are never discarded to let a route recover is a property
    /// of the interface rather than a promise about an implementation.
    /// </para>
    /// <para>
    /// No member of <see cref="AiReliabilityAttempt"/> is provider-supplied text. A failure is
    /// carried as a member of the closed <see cref="AiFailureCategory"/> vocabulary, so exposing
    /// attempts on an operator surface cannot carry vendor error strings with them.
    /// </para>
    /// </remarks>
    IReadOnlyList<AiReliabilityAttempt> AttemptsFor(string providerId, string modelId);

    /// <summary>Every route with evidence, ordered by provider then model so two reads agree.</summary>
    IReadOnlyList<AiReliabilityEvidence> All();
}
