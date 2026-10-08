namespace Nexus.Intelligence.Contracts;

/// <summary>
/// Whether a model is on offer at all, as distinct from whether it is working right now.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is a lifecycle fact and it is not a health fact, which is why the registry carries both.</b>
/// A model is <see cref="Deprecated"/> because its vendor has announced a retirement date; it is
/// unhealthy because a call to it just failed. Collapsing the two would make "we are migrating off
/// this" indistinguishable from "this is broken", and the two demand different responses — the first
/// is a scheduled change, the second is an incident.
/// </para>
/// <para>
/// The vocabulary is deliberately coarser than any vendor's. A provider that distinguishes four kinds
/// of preview access does not get four members here: the registry's job is to decide whether a model
/// may be routed to, and "yes, on the same terms as everything else" is the only preview distinction
/// a router can act on.
/// </para>
/// </remarks>
public enum AiModelAvailability
{
    /// <summary>Not stated. Treated as not routable, because an unstated lifecycle fact is not a permission.</summary>
    Unknown = 0,

    /// <summary>On general offer.</summary>
    Available = 1,

    /// <summary>On offer, but on terms the operator has not accepted as general — access-gated, or subject to change.</summary>
    Preview = 2,

    /// <summary>Still reachable, but scheduled for withdrawal. Not routable, so new work migrates before it breaks.</summary>
    Deprecated = 3,

    /// <summary>Withdrawn. The record is kept so an audit record naming it still resolves.</summary>
    Withdrawn = 4,
}

/// <summary>
/// What is known about a model's ability to serve a call, at this moment.
/// </summary>
/// <remarks>
/// <para>
/// <b>Reported by a health source, never stored as policy.</b> A registry record that carried a
/// hardcoded "healthy" would be a claim about the world that no one maintains, and it would be wrong
/// the first time a provider had an outage. The registry states which models exist; a health source
/// states which of them are working.
/// </para>
/// <para>
/// The members are the ones a routing decision can act on differently. <see cref="RateLimited"/> and
/// <see cref="Degraded"/> are routable, because a throttled or slower provider still answers and
/// refusing to route to it would turn a degradation into an outage. <see cref="AuthError"/> is not
/// routable even though the endpoint is reachable: a credential failure cannot be retried into
/// success and is the one health state that always needs a person.
/// </para>
/// </remarks>
public enum AiModelHealthState
{
    /// <summary>Nothing has reported. Not routable: an unreported provider is not a healthy one.</summary>
    Unknown = 0,

    /// <summary>Serving normally.</summary>
    Available = 1,

    /// <summary>Serving, but throttling. Routable, and ranked below an unthrottled route.</summary>
    RateLimited = 2,

    /// <summary>Serving, but slower or less reliably than its normal state. Routable, and ranked below.</summary>
    Degraded = 3,

    /// <summary>Reachable and refusing the credential. Not routable, and never resolved by retrying.</summary>
    AuthError = 4,

    /// <summary>Not serving. Not routable.</summary>
    Unavailable = 5,

    /// <summary>Switched off by an operator. Not routable, and not re-enabled by a failover.</summary>
    Disabled = 6,
}

/// <summary>What a model can take in or give back.</summary>
/// <remarks>
/// A modality a model does not declare is a modality it cannot be sent. The registry never infers one:
/// a text model is not assumed to accept images because its vendor ships an image model.
/// </remarks>
public enum AiModelModality
{
    /// <summary>Text.</summary>
    Text = 0,

    /// <summary>Still images.</summary>
    Image = 1,

    /// <summary>Audio.</summary>
    Audio = 2,

    /// <summary>Video.</summary>
    Video = 3,
}

/// <summary>
/// How much reasoning a model is capable of, on an ordered scale.
/// </summary>
/// <remarks>
/// <para>
/// Ordered because the routing rule is a minimum: a capability that requires
/// <see cref="Medium"/> is not served by a model declaring <see cref="Low"/>. The comparison is the
/// control, so the numbering is load-bearing in the way
/// <see cref="AiGovernanceVerdict"/>'s is — and, unlike that one, ascending here means
/// <em>more</em> capable rather than <em>more</em> restrictive.
/// </para>
/// <para>
/// <b>A class and not a score.</b> No member claims a model is better than another at a task; it
/// claims the model can be asked to reason at that depth at all. Nothing in the estate may treat
/// <see cref="Max"/> as "the good one" and route everything to it — the ranking is what decides
/// preference, and it is configured.
/// </para>
/// </remarks>
public enum AiReasoningClass
{
    /// <summary>No reasoning mode. Answers directly.</summary>
    None = 0,

    /// <summary>Light reasoning.</summary>
    Low = 1,

    /// <summary>Substantial reasoning.</summary>
    Medium = 2,

    /// <summary>Deep reasoning.</summary>
    High = 3,

    /// <summary>The deepest class the registry models. Not a default and not a target.</summary>
    Max = 4,
}

/// <summary>
/// How quickly a model is expected to answer, as a class rather than as a duration.
/// </summary>
/// <remarks>
/// <para>
/// <b>A class and not a measurement, because the estate has no measurement.</b> A field in
/// milliseconds would be a number somebody typed, presented with the precision of an instrument the
/// estate does not own. What an operator can honestly state is "this route is one of the fast ones",
/// and that is enough for a ranking to prefer it — which is the only thing W7C does with the value.
/// </para>
/// <para>
/// <b>Enforcing a caller's <c>LatencyBudget</c> is deliberately not this.</b> Turning a class into a
/// ceiling requires a conversion the estate cannot yet justify, and the evidence that would justify it
/// — observed latency per route — is the operations lane's artifact. W7C ranks on speed and records
/// the caller's budget; it does not claim to have checked a ceiling it has no evidence for.
/// </para>
/// </remarks>
public enum AiRelativeSpeed
{
    /// <summary>Not stated. Contributes nothing to a ranking and is not a claim of slowness.</summary>
    Unknown = 0,

    /// <summary>Among the fastest routes the estate knows of.</summary>
    VeryFast = 1,

    /// <summary>Fast.</summary>
    Fast = 2,

    /// <summary>Ordinary.</summary>
    Normal = 3,

    /// <summary>Slow. Still routable; ranked below an otherwise equal faster route.</summary>
    Slow = 4,
}

/// <summary>How each vocabulary member reads for the two questions routing asks.</summary>
/// <remarks>
/// The predicates live here, beside the vocabularies they read, rather than as conditions inside the
/// router. A routing filter written as <c>state is not (Unavailable or Disabled)</c> drifts from the
/// enum the moment a member is added, and the drift is silent: a new health state defaults into
/// "routable" because it was not in a list nobody remembered to update. A method beside the enum has
/// the same failure mode in principle, but it is the file a reviewer opens when adding the member.
/// </remarks>
public static class AiRegistryVocabularyExtensions
{
    /// <summary>True when the model is on offer and may be routed to on its lifecycle state alone.</summary>
    public static bool IsRoutable(this AiModelAvailability availability)
        => availability is AiModelAvailability.Available or AiModelAvailability.Preview;

    /// <summary>True when the route is worth attempting, on its reported health alone.</summary>
    public static bool IsRoutable(this AiModelHealthState health)
        => health is AiModelHealthState.Available
            or AiModelHealthState.RateLimited
            or AiModelHealthState.Degraded;

    /// <summary>
    /// How healthy a routable state is, as a 0..1 score component.
    /// </summary>
    /// <remarks>
    /// Only defined for routable states; a non-routable state scores zero rather than being rejected
    /// here, because rejecting is the filter's job and scoring is the ranker's. Two callers reading
    /// one method and disagreeing about whether zero means "worst" or "excluded" is how a rejected
    /// candidate ends up ranked.
    /// </remarks>
    public static double Score(this AiModelHealthState health) => health switch
    {
        AiModelHealthState.Available => 1.0,
        AiModelHealthState.Degraded => 0.6,
        AiModelHealthState.RateLimited => 0.3,
        _ => 0.0,
    };

    /// <summary>How far a trust tier counts toward remote-egress confidence, as a 0..1 score component.</summary>
    public static double Score(this AiProviderTrustTier trust) => trust switch
    {
        AiProviderTrustTier.Sovereign => 1.0,
        AiProviderTrustTier.Approved => 0.75,
        AiProviderTrustTier.Restricted => 0.4,
        _ => 0.0,
    };

    /// <summary>How much reasoning headroom a class represents, as a 0..1 score component.</summary>
    public static double Score(this AiReasoningClass reasoning)
        => (int)reasoning / (double)(int)AiReasoningClass.Max;

    /// <summary>
    /// How favourable a speed class is, as a 0..1 score component.
    /// </summary>
    /// <remarks>
    /// <see cref="AiRelativeSpeed.Unknown"/> scores zero rather than a middle value. A middle value
    /// would be a guess presented as a measurement, and it would let an unstated speed outrank a route
    /// an operator has explicitly described as slow — which is the ranking getting quieter the less
    /// anyone knows.
    /// </remarks>
    public static double Score(this AiRelativeSpeed speed) => speed switch
    {
        AiRelativeSpeed.VeryFast => 1.0,
        AiRelativeSpeed.Fast => 0.75,
        AiRelativeSpeed.Normal => 0.5,
        AiRelativeSpeed.Slow => 0.25,
        _ => 0.0,
    };
}
