namespace Nexus.Intelligence.Contracts;

/// <summary>Where AI execution may physically happen for a given classification.</summary>
/// <remarks>
/// A coarse destination vocabulary, not a provider list. Naming providers here would make this type a
/// routing table and re-introduce provider selection at the policy layer. Which concrete provider
/// satisfies a destination class is decided below the boundary.
/// </remarks>
public enum AiDestinationClass
{
    /// <summary>On infrastructure the tenant or operator controls. Nothing leaves the estate.</summary>
    Local = 0,

    /// <summary>A third-party provider over the network.</summary>
    RemoteProvider = 1,
}

/// <summary>What must happen to content of a given classification before it may be sent.</summary>
public sealed record DataExposureRule
{
    /// <summary>The classification this rule governs.</summary>
    public required DataClassification Classification { get; init; }

    /// <summary>Destination classes this classification may reach. Empty means it may not leave at all.</summary>
    public IReadOnlyList<AiDestinationClass> AllowedDestinations { get; init; } = [];

    /// <summary>True when content of this classification must pass through redaction before egress.</summary>
    public bool RequiresRedaction { get; init; }

    /// <summary>True when content of this classification may be sent in full, with no filtering.</summary>
    public bool EgressPermitted => AllowedDestinations.Count > 0;

    /// <summary>
    /// True when the rule forbids egress entirely. Content may still be processed locally.
    /// </summary>
    public bool IsLocalOnly => AllowedDestinations.Count == 1 && AllowedDestinations[0] == AiDestinationClass.Local;

    /// <summary>Why the rule is what it is. Required, so the table is reviewable.</summary>
    public required string Rationale { get; init; }
}

/// <summary>
/// The table that decides what content may leave, for where, and after what treatment.
/// </summary>
/// <remarks>
/// <para>
/// The exposure model that sits between a caller and any AI execution:
/// <c>caller → exposure policy → context builder → redaction/filtering → AI execution</c>.
/// This type is the second stage. It is deliberately deterministic and contains no provider logic:
/// <b>provider-specific filtering is not implemented in W7A</b>, and none of these rules names a
/// provider. A rule states a <em>destination class</em>, and the AI Head decides which provider
/// satisfies it.
/// </para>
/// <para>
/// The default table is conservative by construction: the three most sensitive classifications may
/// not leave the estate at all, and everything above <see cref="DataClassification.Internal"/>
/// requires redaction. A permissive default is the failure mode this type exists to prevent, because
/// a default is what applies when nobody thought about the case.
/// </para>
/// </remarks>
public sealed class DataExposurePolicy
{
    private readonly Dictionary<DataClassification, DataExposureRule> _rules;

    /// <summary>Builds a policy from rules, requiring exactly one rule per classification.</summary>
    /// <exception cref="ArgumentException">A classification is missing a rule, or has more than one.</exception>
    public DataExposurePolicy(IEnumerable<DataExposureRule> rules)
    {
        ArgumentNullException.ThrowIfNull(rules);

        _rules = new Dictionary<DataClassification, DataExposureRule>();

        foreach (var rule in rules)
        {
            if (rule is null)
            {
                throw new ArgumentException("The exposure policy may not contain a null rule.", nameof(rules));
            }

            if (!Enum.IsDefined(rule.Classification))
            {
                throw new ArgumentException(
                    $"The exposure policy contains a rule for an undefined classification '{rule.Classification}'.",
                    nameof(rules));
            }

            if (!_rules.TryAdd(rule.Classification, rule))
            {
                throw new ArgumentException(
                    $"The exposure policy contains more than one rule for '{rule.Classification}'. A duplicate " +
                    "rule makes the effective policy depend on enumeration order.",
                    nameof(rules));
            }
        }

        // A missing rule is refused rather than defaulted. Every classification this contract defines
        // must have a decision, because the alternative - a fallback - is the permissive default this
        // type exists to prevent.
        foreach (var classification in Enum.GetValues<DataClassification>())
        {
            if (!_rules.ContainsKey(classification))
            {
                throw new ArgumentException(
                    $"The exposure policy has no rule for '{classification}'. Every classification must be " +
                    "decided explicitly; a missing rule is not permitted to fall back to a default.",
                    nameof(rules));
            }
        }
    }

    /// <summary>The rule governing a classification.</summary>
    public DataExposureRule RuleFor(DataClassification classification) => _rules[classification];

    /// <summary>Every rule, ordered by ascending classification.</summary>
    public IReadOnlyList<DataExposureRule> Rules
        => _rules.Values.OrderBy(r => (int)r.Classification).ToArray();

    /// <summary>
    /// The default table: the policy that applies when none is configured.
    /// </summary>
    /// <remarks>
    /// <see cref="DataClassification.Secret"/> may not egress at all, in any form, redacted or not. A
    /// secret that has been "redacted" by a heuristic is still a secret that reached a redactor on the
    /// way out, and the only reliable control for a credential is that it never leaves.
    /// </remarks>
    public static DataExposurePolicy Default() => new(
    [
        new DataExposureRule
        {
            Classification = DataClassification.Public,
            AllowedDestinations = [AiDestinationClass.Local, AiDestinationClass.RemoteProvider],
            Rationale = "Already publishable; no exposure constraint applies.",
        },
        new DataExposureRule
        {
            Classification = DataClassification.Internal,
            AllowedDestinations = [AiDestinationClass.Local, AiDestinationClass.RemoteProvider],
            Rationale = "Ordinary internal material, not personal and not customer-owned. May egress unredacted.",
        },
        new DataExposureRule
        {
            Classification = DataClassification.Confidential,
            AllowedDestinations = [AiDestinationClass.Local, AiDestinationClass.RemoteProvider],
            RequiresRedaction = true,
            Rationale = "Commercial-in-confidence. Egress permitted only after direct identifiers are removed.",
        },
        new DataExposureRule
        {
            Classification = DataClassification.Pii,
            AllowedDestinations = [AiDestinationClass.Local, AiDestinationClass.RemoteProvider],
            RequiresRedaction = true,
            Rationale = "Personal data. Redaction precedes egress; a local destination is always available.",
        },
        new DataExposureRule
        {
            Classification = DataClassification.Financial,
            AllowedDestinations = [AiDestinationClass.Local, AiDestinationClass.RemoteProvider],
            RequiresRedaction = true,
            Rationale = "Financial records. Redaction precedes egress; figures may leave, identities may not.",
        },
        new DataExposureRule
        {
            Classification = DataClassification.SourceCode,
            AllowedDestinations = [AiDestinationClass.Local, AiDestinationClass.RemoteProvider],
            RequiresRedaction = true,
            Rationale =
                "Source is not customer data, but may embed identifiers, endpoints or credentials. Redaction " +
                "precedes egress; a local destination keeps it in the estate.",
        },
        new DataExposureRule
        {
            Classification = DataClassification.CustomerData,
            AllowedDestinations = [AiDestinationClass.Local],
            RequiresRedaction = true,
            Rationale =
                "Held on a customer's behalf. Local-only by default: the operator cannot consent to a third " +
                "party on the customer's behalf, so remote egress requires an explicit, recorded change.",
        },
        new DataExposureRule
        {
            Classification = DataClassification.Secret,
            AllowedDestinations = [],
            Rationale =
                "A credential must never reach any AI destination, including a local one and including in " +
                "redacted form. There is no rule under which this classification egresses.",
        },
    ]);
}
