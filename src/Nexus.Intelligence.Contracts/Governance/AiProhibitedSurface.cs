namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The category of protected surface that makes AI participation forbidden.
/// </summary>
/// <remarks>
/// <para>
/// A declaration of <see cref="AiDependencyClass.AiProhibited"/> must name one of these. The category
/// is required because <b>"prohibited" without a stated basis is a label, and a label is not a
/// control</b> — a reviewer needs to know which protection the prohibition exists to preserve, or
/// they cannot tell whether it is still needed.
/// </para>
/// <para>
/// The first five surfaces are the <b>baseline</b>: every one of them must be covered before a
/// registry may be treated as authoritative. See <see cref="AiProhibitionBaseline"/>. The sixth is
/// open-ended by design — a Product may prohibit AI from its own capability, and no fixed list could
/// enumerate what Products will need to forbid.
/// </para>
/// <para>
/// <b>The surfaces belong to Platform's deterministic authority, not to AI Governance.</b> That is
/// the point of the class: AI Governance governs models, providers, prompts, context and cost, and it
/// may not override Platform Governance. A surface on this list is one where the V3 authority rule
/// stops being a principle and becomes a prohibition.
/// </para>
/// </remarks>
public enum AiProhibitedSurface
{
    /// <summary>
    /// Platform Governance authority. AI must never decide, score, rank, gate, approve, reject or
    /// otherwise participate in a governance decision, and its output must never be an input a
    /// deterministic governance rule consumes. AI may advise a <em>person</em>; it may not be in the
    /// decision path.
    /// </summary>
    PlatformGovernanceAuthority = 0,

    /// <summary>
    /// Protected Git and merge authority: whether a change may land, on which branch, under what
    /// review and what the resulting history is. AI does not merge, approve, bypass, sign off or
    /// unblock a protected branch.
    /// </summary>
    ProtectedGitMergeAuthority = 1,

    /// <summary>
    /// Secret custody: which secrets exist, where they are held, who may resolve them and when they
    /// are rotated or revoked. AI participates in none of it — not reading, not listing, not
    /// comparing, not summarising.
    /// </summary>
    SecretCustody = 2,

    /// <summary>
    /// Credential material itself: the value, any fragment of it, or any transform of it. Distinct
    /// from <see cref="SecretCustody"/> — that surface is the <em>handling</em> of secrets, this one
    /// is the <em>material</em>. A path can breach either without breaching the other, which is why
    /// they are two entries and not one.
    /// </summary>
    CredentialMaterial = 3,

    /// <summary>
    /// Deterministic security gates: authorisation checks, tenancy isolation, exposure decisions,
    /// input validation and any other check whose result must be reproducible and auditable. AI may
    /// not evaluate, soften, override or pre-filter one.
    /// </summary>
    DeterministicSecurityGate = 4,

    /// <summary>
    /// An explicitly prohibited Product capability. Declared by the Head or Product that owns it, for
    /// a surface the five baseline categories do not name. This is the open end of the vocabulary.
    /// </summary>
    ProhibitedProductCapability = 5,
}

/// <summary>
/// Which prohibited surfaces must be covered before a dependency registry is authoritative.
/// </summary>
/// <remarks>
/// <para>
/// The baseline exists so that the five cross-cutting prohibitions cannot be forgotten one at a time.
/// A registry that omits <see cref="AiProhibitedSurface.SecretCustody"/> is not "a registry with a
/// gap" — it is a registry that silently states AI may participate in secret custody, because
/// absence of a prohibition is what every consumer will read it as.
/// </para>
/// <para>
/// This type deliberately ships the <b>surfaces</b> and not ready-made declarations. Who owns each
/// prohibition, and why it exists, are answers only the owning Head or Product can give; a contract
/// assembly that invented them would be writing a rationale on someone else's behalf.
/// </para>
/// </remarks>
public static class AiProhibitionBaseline
{
    /// <summary>
    /// The five surfaces every authoritative registry must declare prohibited. Excludes
    /// <see cref="AiProhibitedSurface.ProhibitedProductCapability"/>, which is declared by the Product
    /// that needs it rather than by the baseline.
    /// </summary>
    public static IReadOnlyList<AiProhibitedSurface> RequiredSurfaces { get; } =
    [
        AiProhibitedSurface.PlatformGovernanceAuthority,
        AiProhibitedSurface.ProtectedGitMergeAuthority,
        AiProhibitedSurface.SecretCustody,
        AiProhibitedSurface.CredentialMaterial,
        AiProhibitedSurface.DeterministicSecurityGate,
    ];

    /// <summary>Every declared surface: the baseline plus the open-ended Product category.</summary>
    public static IReadOnlyList<AiProhibitedSurface> AllSurfaces { get; } =
    [
        .. RequiredSurfaces,
        AiProhibitedSurface.ProhibitedProductCapability,
    ];

    /// <summary>True when a surface is part of the mandatory baseline.</summary>
    public static bool IsRequired(AiProhibitedSurface surface) => RequiredSurfaces.Contains(surface);
}
