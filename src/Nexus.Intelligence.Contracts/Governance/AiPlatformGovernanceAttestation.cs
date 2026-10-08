namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The identifiers of the deterministic authorities whose decision outranks AI Governance.
/// </summary>
/// <remarks>
/// <para>
/// Constants for the same reason <see cref="AiGovernanceRules"/> holds constants: an authority name
/// that configuration could rename is an authority name an audit record cannot be resolved against.
/// The set is small on purpose — these are the authorities the V3 authority rule names, not every
/// deterministic check in the estate.
/// </para>
/// <para>
/// <b>These belong to Platform Governance.</b> Nothing in the AI Head writes one; they exist here so
/// that an attestation crossing into AI Governance can name the authority it came from, and so that
/// the mapping from an authority to the protected surface it defends is stated once.
/// </para>
/// </remarks>
public static class AiGovernanceAuthority
{
    /// <summary>
    /// No deterministic authority is involved: the identifier carried by
    /// <see cref="AiPlatformGovernanceAttestation.NotApplicable"/>.
    /// </summary>
    /// <remarks>
    /// A distinct identifier rather than reusing <see cref="PlatformGovernance"/> for the "nothing to
    /// govern" case. Reusing it would make an AI execution with no platform action attached resolve to
    /// the platform-governance protected surface, and the prohibition would refuse every internal
    /// execution in the estate — a governance engine that blocks all work is one that gets disabled.
    /// The two states are different facts and they get different names.
    /// </remarks>
    public const string None = "platform.none";

    /// <summary>Platform Governance authority over protected-system actions.</summary>
    public const string PlatformGovernance = "platform.governance";

    /// <summary>Protected Git and merge authority: whether a change may land.</summary>
    public const string ProtectedGitMerge = "platform.git.protected-merge";

    /// <summary>Secret custody: which secrets exist and who may resolve them.</summary>
    public const string SecretCustody = "platform.secrets.custody";

    /// <summary>Deployment authority.</summary>
    public const string Deployment = "platform.deploy";

    /// <summary>Protected architecture authority.</summary>
    public const string ProtectedArchitecture = "platform.architecture.protected";

    /// <summary>
    /// The protected surface an authority defends, or <see langword="null"/> when the authority is not
    /// one AI is forbidden from participating in.
    /// </summary>
    /// <remarks>
    /// A total mapping, not a lookup with a silent default. An authority this method does not recognise
    /// returns <see langword="null"/> — "not a protected surface" — and that is the correct reading
    /// rather than a permissive one: <see cref="AiProhibitedSurface"/> enumerates the surfaces on which
    /// AI is forbidden, and an authority outside that enumeration is governed by ordinary policy and
    /// the prohibition register, not by this mapping.
    /// </remarks>
    public static AiProhibitedSurface? SurfaceFor(string? authorityId) => authorityId switch
    {
        PlatformGovernance => AiProhibitedSurface.PlatformGovernanceAuthority,
        ProtectedGitMerge => AiProhibitedSurface.ProtectedGitMergeAuthority,
        SecretCustody => AiProhibitedSurface.SecretCustody,
        ProtectedArchitecture => AiProhibitedSurface.PlatformGovernanceAuthority,

        // Deployment is a protected-system action but is not one of the six enumerated surfaces. It is
        // refused by the prohibition register's capability rules rather than by a surface mapping, and
        // returning null here says exactly that instead of inventing a seventh surface.
        Deployment => null,

        _ => null,
    };

    /// <summary>Every authority identifier this vocabulary defines.</summary>
    public static IReadOnlyList<string> All { get; } =
    [
        None,
        PlatformGovernance,
        ProtectedGitMerge,
        SecretCustody,
        Deployment,
        ProtectedArchitecture,
    ];
}

/// <summary>
/// What deterministic Platform Governance decided about the action this AI execution belongs to.
/// </summary>
/// <remarks>
/// <para>
/// <b>This type is why AI Governance can be subordinate rather than merely instructed to be.</b> The
/// evaluator's only entry point requires one of these, so there is no overload — and therefore no code
/// path — that reaches an AI governance verdict without the platform's decision having been supplied.
/// The final verdict is the most restrictive of the two, so an AI verdict of <c>ALLOW</c> cannot
/// produce a permitted execution when the platform refused.
/// </para>
/// <para>
/// <b>An AI execution is frequently not attached to any platform-governed action at all</b> — a
/// developer asking for a code review is not a protected-system action. That case is represented by
/// <see cref="NotApplicable"/> and not by a permit: "no platform action is involved" and "the platform
/// permitted the action" are different facts, and an audit record that conflated them would show a
/// platform approval that never happened.
/// </para>
/// </remarks>
public sealed record AiPlatformGovernanceAttestation
{
    /// <summary>The deterministic authority the decision came from.</summary>
    public required string AuthorityId { get; init; }

    /// <summary>What that authority decided.</summary>
    public required AiGovernanceVerdict Verdict { get; init; }

    /// <summary>Why, in caller-safe terms. Present when the authority refused.</summary>
    public string? Reason { get; init; }

    /// <summary>
    /// True when the attestation is a real determination by a platform authority, as opposed to
    /// <see cref="NotApplicable"/>.
    /// </summary>
    /// <remarks>
    /// Carried explicitly so that an audit record distinguishes "Platform Governance permitted this"
    /// from "Platform Governance does not govern this". Only the first is evidence of a review.
    /// </remarks>
    public bool AuthorityConsulted { get; init; } = true;

    /// <summary>
    /// The protected surface this attestation's authority defends, where it defends one.
    /// </summary>
    public AiProhibitedSurface? Surface => AiGovernanceAuthority.SurfaceFor(AuthorityId);

    /// <summary>A determination that the action may proceed.</summary>
    public static AiPlatformGovernanceAttestation Permit(string authorityId) => new()
    {
        AuthorityId = authorityId,
        Verdict = AiGovernanceVerdict.Allow,
    };

    /// <summary>A determination that the action may not proceed.</summary>
    public static AiPlatformGovernanceAttestation Refuse(string authorityId, string reason) => new()
    {
        AuthorityId = authorityId,
        Verdict = AiGovernanceVerdict.Block,
        Reason = reason,
    };

    /// <summary>
    /// No deterministic platform action is attached to this AI execution.
    /// </summary>
    /// <remarks>
    /// The AI Head's own internal executions — a background summarisation, a scheduled evaluation —
    /// have no platform action to be governed by, and saying so is more honest than fabricating a
    /// permit. The prohibition register still applies in full: an execution with no platform action can
    /// still touch a prohibited surface, and that is what
    /// <see cref="AiGovernanceRules.ProhibitedSurface"/> refuses.
    /// </remarks>
    public static AiPlatformGovernanceAttestation NotApplicable { get; } = new()
    {
        AuthorityId = AiGovernanceAuthority.None,
        Verdict = AiGovernanceVerdict.Allow,
        AuthorityConsulted = false,
        Reason = "No deterministic platform action is attached to this AI execution.",
    };

    /// <summary>The decision projected onto the audit record's policy-decision shape.</summary>
    public AiPolicyDecision ToPolicyDecision() => new()
    {
        Allowed = Verdict is AiGovernanceVerdict.Allow,
        RulesApplied = [AuthorityId],
        Reason = Verdict is AiGovernanceVerdict.Allow ? null : Reason,
    };
}
