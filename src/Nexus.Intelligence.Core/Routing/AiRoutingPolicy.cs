using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Registry;

namespace Nexus.Intelligence.Core.Routing;

/// <summary>
/// How the router chooses between routes that governance and eligibility have already permitted.
/// </summary>
/// <remarks>
/// <para>
/// <b>Configuration, and the only lever an operator has over preference.</b> Nothing here can widen
/// what is permitted — the objective selects a ranking over a set that has already survived every
/// gate — so a misconfigured policy produces a suboptimal route and never an ungoverned one. That
/// asymmetry is what makes this type safe to expose as configuration at all.
/// </para>
/// <para>
/// <b>Validated at construction.</b> <see cref="Validate"/> is called by the router's constructor, so
/// a policy with a negative fallback depth fails where it is composed rather than on the request that
/// first needs a fallback.
/// </para>
/// </remarks>
public sealed record AiRoutingPolicy
{
    /// <summary>What the ranking optimises. Absent means <see cref="AiRoutingObjective.Balanced"/>.</summary>
    public AiRoutingObjective Objective { get; init; } = AiRoutingObjective.Balanced;

    /// <summary>
    /// How many routes beyond the primary a failover may walk.
    /// </summary>
    /// <remarks>
    /// Zero is a legitimate and deliberate setting: it says an estate would rather fail than degrade
    /// onto a second provider. It is not the same as "unset" and is not read as unlimited, which is
    /// the reading that would let a typing omission turn every request into a walk across the whole
    /// registry.
    /// </remarks>
    public int FallbackDepth { get; init; } = 1;

    /// <summary>A balanced ranking with one fallback.</summary>
    public static AiRoutingPolicy Default { get; } = new();

    /// <summary>Reads a policy from its configuration entry, refusing a malformed one.</summary>
    /// <exception cref="InvalidOperationException">
    /// The objective is not a known member, or the depth is negative.
    /// </exception>
    /// <remarks>
    /// Parsed here rather than in the composition root so the failure is exercisable without a host.
    /// <see cref="AiRoutingConfigurationEntry.Objective"/> is a string because configuration has no
    /// enums, and the parse is by NAME through
    /// <see cref="ConfigurationEnum.Parse{TEnum}"/> — a numeral is refused rather than bound by
    /// position, so <c>Objective: "1"</c> cannot silently become whichever objective is numbered 1.
    /// </remarks>
    public static AiRoutingPolicy From(AiRoutingConfigurationEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);

        var objective = ConfigurationEnum.Parse(
            entry.Objective,
            AiRoutingObjective.Balanced,
            "Ai:Registry:Routing:Objective",
            "routing objective");

        var policy = new AiRoutingPolicy
        {
            Objective = objective,
            FallbackDepth = entry.FallbackDepth,
        };

        policy.Validate();

        return policy;
    }

    /// <summary>The weight each scoring component carries under <see cref="Objective"/>.</summary>
    internal AiRoutingWeights Weights => AiRoutingWeights.For(Objective);

    /// <summary>Refuses a policy that could not be applied as written.</summary>
    /// <exception cref="InvalidOperationException">The policy is malformed.</exception>
    public void Validate()
    {
        if (!Enum.IsDefined(Objective))
        {
            throw new InvalidOperationException(
                $"Ai routing policy: '{Objective}' is not a known routing objective.");
        }

        if (FallbackDepth < 0)
        {
            // Refused rather than read as "no bound". The field is documented as a depth, so a
            // negative value is a malformed policy, and the conservative reading of a record that
            // cannot be interpreted has been a refusal everywhere else in this lane.
            throw new InvalidOperationException(
                $"Ai routing policy: FallbackDepth {FallbackDepth} is negative, and a depth is a count. "
                + "Use 0 to state that no fallback may be attempted.");
        }
    }
}

/// <summary>
/// The scoring weights behind one routing objective.
/// </summary>
/// <remarks>
/// <para>
/// Every row sums to 1, so a score is comparable across objectives and a component's weight is
/// readable as a share of the decision. The rows are deliberately few: six components and six
/// objectives is a table a reviewer can check by eye, and a table a reviewer cannot check by eye is
/// one where a weighting error survives review.
/// </para>
/// <para>
/// <b>No weights exist for "the best model".</b> There is a reasoning component and a reliability
/// component and they are not the same thing, and neither is a claim that a particular model is
/// better at a particular task. What the estate knows about a route is what its registration declares;
/// quality evidence is the evaluation lane's artifact, and when it arrives it arrives as a component
/// here rather than as a hardcoded preference.
/// </para>
/// </remarks>
internal sealed record AiRoutingWeights(
    double Cost,
    double Reliability,
    double Reasoning,
    double Health,
    double Priority,
    double Speed)
{
    /// <summary>The weights for an objective. Every row sums to 1.</summary>
    internal static AiRoutingWeights For(AiRoutingObjective objective) => objective switch
    {
        AiRoutingObjective.CheapestEligible => new(1.00, 0.00, 0.00, 0.00, 0.00, 0.00),

        // Cost-led, but a cheap route that is untrusted or unhealthy does not win on price alone.
        AiRoutingObjective.CheapestReliable => new(0.45, 0.30, 0.00, 0.15, 0.10, 0.00),

        // Trust-led, with cost reduced to a tie-breaker rather than a criterion.
        AiRoutingObjective.HighestReliability => new(0.10, 0.70, 0.10, 0.10, 0.00, 0.00),

        // Reasoning-led, for capabilities whose work is the reasoning.
        AiRoutingObjective.HighestReasoning => new(0.10, 0.10, 0.60, 0.10, 0.10, 0.00),

        // The operator's explicit ordering, with no inferred component at all.
        AiRoutingObjective.ConfiguredOrder => new(0.00, 0.00, 0.00, 0.00, 1.00, 0.00),

        // Cost, trust, reasoning headroom, health, operator preference and speed, in proportion.
        _ => new(0.25, 0.25, 0.15, 0.15, 0.10, 0.10),
    };
}
