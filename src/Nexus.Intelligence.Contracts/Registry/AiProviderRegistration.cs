using System.Text.RegularExpressions;

namespace Nexus.Intelligence.Contracts;

/// <summary>
/// One provider, as the registry states it: how it is reached, what it may receive, and on what terms.
/// </summary>
/// <remarks>
/// <para>
/// <b>The registry holds a credential's <em>name</em> and has no member that could hold its value.</b>
/// <see cref="SecretReference"/> is an environment-variable name — <c>NEXUS_OPENAI_API_KEY</c> — and
/// the value is resolved at the point of use by the platform's
/// <c>ISecretResolver</c>, which the registry never sees and cannot call. That is a structural
/// guarantee rather than a review discipline: there is nowhere on this type to write a secret, so no
/// registry edit, serialization or log can carry one. It is what makes the directive's "never secret
/// values" a property of the shape instead of a rule someone has to remember.
/// </para>
/// <para>
/// <b>Health is deliberately absent, and is supplied by <see cref="IAiModelHealthSource"/> instead.</b>
/// A health field here would be a value written once at configuration time and read as though it were
/// current, which is a claim about the world that nothing maintains. The registry can honestly state
/// what a provider <em>is</em>; only a health source can state how it is doing.
/// </para>
/// <para>
/// As with <see cref="AiModelRegistration"/>, every default refuses: not enabled, untrusted, no
/// egress, and unapproved.
/// </para>
/// </remarks>
public sealed record AiProviderRegistration
{
    /// <summary>
    /// The provider identifier, lower-case and stable, as the registry and the governance register
    /// both state it — <c>openai</c>, <c>anthropic</c>.
    /// </summary>
    /// <remarks>
    /// <b>Stable, because it is an audit key.</b> It is half of the governance register's model key
    /// and it is written into every decision record, so renaming a provider rewrites history. The
    /// display name is the field that may change freely.
    /// </remarks>
    public required string ProviderId { get; init; }

    /// <summary>A human-readable name, for reports. Never used to decide anything.</summary>
    public required string DisplayName { get; init; }

    /// <summary>
    /// Which implementation actually serves this provider, as an assembly-qualified type name.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The registry's only pointer from data to code. It exists so that "which adapter serves
    /// <c>openai</c>" is a declarative fact an operator can read and audit, rather than something
    /// discovered by reading the composition root.
    /// </para>
    /// <para>
    /// It is recorded and validated as a name; the registry does not load the type. Type resolution
    /// from configuration is a capability the estate does not need and should not have — a config
    /// file that can name any type to instantiate is a config file that can instantiate anything.
    /// </para>
    /// </remarks>
    public required string AdapterIdentity { get; init; }

    /// <summary>The capabilities this provider is able to serve at all, across all of its models.</summary>
    /// <remarks>
    /// Distinct from a model's capabilities and both are applied. A provider may support a capability
    /// in general while the specific model selected does not declare it, and the narrower of the two
    /// governs — the request must survive both.
    /// </remarks>
    public IReadOnlyList<CapabilityId> Capabilities { get; init; } = [];

    /// <summary>Whether an operator has switched the provider on.</summary>
    public bool Enabled { get; init; }

    /// <summary>
    /// The environment-variable name the provider's credential is read from, or null where none is
    /// needed.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A name and never a value — see the remarks on this type. Null is correct and not an omission
    /// for a provider that runs on infrastructure the operator controls and authenticates by network
    /// position rather than by credential.
    /// </para>
    /// <para>
    /// The approved reference for OpenAI remains <c>NEXUS_OPENAI_API_KEY</c>. The vendor-conventional
    /// <c>OPENAI_API_KEY</c> is deliberately not used, because a name that a vendor's own SDK reads
    /// implicitly is a name the estate cannot reason about: it would let a library pick up a value
    /// that the estate never resolved and never recorded resolving.
    /// </para>
    /// </remarks>
    public string? SecretReference { get; init; }

    /// <summary>True when content may reach this provider over the network at all.</summary>
    public bool PermitsRemoteEgress { get; init; }

    /// <summary>How far the provider is trusted with content, as a governed fact.</summary>
    public AiProviderTrustTier Trust { get; init; } = AiProviderTrustTier.Untrusted;

    /// <summary>
    /// An operator's ordinal preference between providers. Higher is preferred.
    /// </summary>
    /// <remarks>
    /// Ordinal and compared, never summed: it expresses "when these two are otherwise equal, prefer
    /// this one", which is a decision an operator can make and defend. It is the tie-breaker beneath
    /// the configured objective, and the whole ordering when the objective is
    /// <see cref="AiRoutingObjective.ConfiguredOrder"/>.
    /// </remarks>
    public int Priority { get; init; }

    /// <summary>
    /// A cardinal multiplier on this provider's contribution to a routing score. Defaults to 1.
    /// </summary>
    /// <remarks>
    /// Where <see cref="Priority"/> says "prefer this one", weight says "prefer this one <em>by this
    /// much</em>" and composes with the objective's own weights. It is a multiplier and not a score
    /// component, so a weight of zero removes a provider's influence without removing the provider —
    /// which is the honest way to express "reachable, but not preferred".
    /// </remarks>
    public double Weight { get; init; } = 1.0;

    /// <summary>Whether the provider has been approved for use by AI Governance.</summary>
    public AiGovernanceApprovalStatus Approval { get; init; } = AiGovernanceApprovalStatus.Unregistered;

    /// <summary>The most sensitive classification this provider is cleared to receive.</summary>
    public DataClassification MaxClassification { get; init; } = DataClassification.Public;

    /// <summary>Who approved it. Required for an approval to be reviewable.</summary>
    public string? ApprovedBy { get; init; }

    /// <summary>Why it is in the state it is in. Required, so no entry arrives without a reason.</summary>
    public required string GovernanceRationale { get; init; }

    /// <summary>True when this provider claims to serve the capability.</summary>
    public bool Declares(CapabilityId capability)
    {
        ArgumentNullException.ThrowIfNull(capability);

        return Capabilities.Contains(capability);
    }

    /// <summary>
    /// The shape an environment-variable name must have to be accepted as a secret reference.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Upper-case letters, digits and underscores, starting with a letter. The rule is narrow on
    /// purpose, and its narrowness is what makes it a guard: <b>every published vendor key format
    /// contains a character this pattern cannot match</b> — a lower-case letter, a hyphen, or a dot —
    /// so a value pasted into a reference field where a name belongs is rejected rather than stored.
    /// </para>
    /// <para>
    /// <b>It is not a total guard and is not claimed to be.</b> An all-upper-case, underscore-only
    /// credential would satisfy this pattern. What makes that case survivable is not this check but
    /// the type it sits on: no member of <see cref="AiProviderRegistration"/> can hold a value, so a
    /// string that passes here is still only ever used as a lookup key.
    /// </para>
    /// </remarks>
    private static readonly Regex SecretReferenceShape = new(
        "^[A-Z][A-Z0-9_]{2,}$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>True when the string is shaped like an environment-variable name and not like a key.</summary>
    public static bool IsWellFormedSecretReference(string? candidate)
        => !string.IsNullOrWhiteSpace(candidate) && SecretReferenceShape.IsMatch(candidate);
}
