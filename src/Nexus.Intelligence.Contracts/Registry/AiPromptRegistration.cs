namespace Nexus.Intelligence.Contracts;

/// <summary>
/// One prompt or instruction set, as the registry states it: its text, at a version, under an owner.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the only type in the register family that carries text, and that is the point.</b>
/// <see cref="AiPromptGovernanceRecord"/> deliberately does not: an audit record and a governance
/// register are both durable stores, and a prompt body in either would be prompt text retained
/// outside the store that owns it. The body has to live <em>somewhere</em> — before W7D it lived in
/// C# string literals, one of them a three-line JSON-shape instruction compiled into the planner, and
/// another assembled in five fragments inside the prompt step. An instruction set that is compiled
/// into an assembly cannot be versioned, cannot be reviewed, cannot be changed by the person who owns
/// its behaviour, and changes whenever anyone rebuilds. This record is where it goes instead.
/// </para>
/// <para>
/// <b>A version is required and is not decorative.</b> The governance engine refuses a prompt named
/// without a version (<see cref="AiGovernanceRules.PromptUnversioned"/>) and refuses one named at a
/// version other than the approved one, on the grounds that "an unreviewed version of an approved
/// prompt is an unapproved prompt". Both refusals are only meaningful if a prompt has versions, so
/// the version is a required member of the definition rather than a label attached at the call site.
/// </para>
/// <para>
/// <b>The text is bounded and non-empty by construction.</b> A blank system frame would be a prompt
/// that steers nothing while appearing in the audit record as the instruction set that was applied,
/// so an empty body is refused at composition rather than discovered as an oddly compliant model.
/// </para>
/// </remarks>
public sealed record AiPromptRegistration
{
    /// <summary>The prompt or instruction set identifier. The governance key.</summary>
    public required string PromptId { get; init; }

    /// <summary>
    /// The version of this instruction set.
    /// </summary>
    /// <remarks>
    /// An opaque, operator-stated string rather than a number. A numeric version invites arithmetic —
    /// "the highest version wins" — which is a selection rule nobody wrote and which would silently
    /// apply an unapproved version the moment it was written. A string is compared for equality
    /// against the approved version and nothing else.
    /// </remarks>
    public required string Version { get; init; }

    /// <summary>The accountable owner of this instruction set.</summary>
    public required string Owner { get; init; }

    /// <summary>What this instruction set is for, in the owner's words. Required, so no prompt arrives unexplained.</summary>
    public required string Purpose { get; init; }

    /// <summary>
    /// The instruction text applied to the model as the system frame.
    /// </summary>
    /// <remarks>
    /// The operator-authored half of the frame only. Anything the AI Head generates from the
    /// execution's own facts — the tool list, the in-band call syntax the parser recognises — is
    /// appended by the prompt step and is not configurable, because those strings are coupled to
    /// parsers that read the model's reply. An operator who could edit the call syntax could break
    /// tool parsing from a configuration file, and the failure would look like a model that stopped
    /// using tools.
    /// </remarks>
    public required string SystemFrame { get; init; }

    /// <summary>Whether an operator has switched this instruction set on. Defaults to off.</summary>
    public bool Enabled { get; init; }

    /// <summary>Whether this instruction set has been reviewed and approved at <see cref="Version"/>.</summary>
    public AiGovernanceApprovalStatus Approval { get; init; } = AiGovernanceApprovalStatus.Unregistered;

    /// <summary>Why it is in the state it is in. Required, so no entry arrives without a reason.</summary>
    public required string Rationale { get; init; }

    /// <summary>True when this instruction set is switched on and approved.</summary>
    public bool IsApplicable => Enabled && Approval is AiGovernanceApprovalStatus.Approved;
}

/// <summary>
/// The prompts and instruction sets that exist, and what each of them says.
/// </summary>
/// <remarks>
/// <para>
/// <b>The versioned reference the runtime resolves through.</b> A runtime component names a
/// <c>PromptId</c> and receives a body at the approved version; it does not carry the body. That is
/// what makes "which instruction set produced this answer" answerable from an audit record, and what
/// makes editing an instruction set a reviewable act rather than a code change.
/// </para>
/// <para>
/// No enumeration method, for the reason <see cref="IAiGovernanceRegister"/> gives: the engine never
/// lists the register, it only resolves against it, so a register cannot be asked a question whose
/// answer it would have to materialise.
/// </para>
/// </remarks>
public interface IAiPromptRegistry
{
    /// <summary>Resolves an instruction set, or returns <see langword="false"/> when nothing is registered under that identifier.</summary>
    bool TryGetPrompt(string? promptId, out AiPromptRegistration? prompt);

    /// <summary>How many instruction sets are registered. For composition assertions, not for enumeration.</summary>
    int Count { get; }
}

/// <summary>The registry that knows no prompts: the state before any instruction set has been registered.</summary>
/// <remarks>
/// <b>This is the default, and it refuses everything.</b> A runtime component that resolves no
/// instruction set cannot assemble a system frame, and an execution that names no prompt is refused
/// by <see cref="AiGovernanceRules.PromptUnregistered"/> once one is named. An estate with no
/// registered prompts runs no governed execution, which is the correct reading of "no instruction
/// sets have been reviewed".
/// </remarks>
public sealed class EmptyAiPromptRegistry : IAiPromptRegistry
{
    /// <summary>The single instance. The registry is stateless.</summary>
    public static readonly EmptyAiPromptRegistry Instance = new();

    /// <inheritdoc />
    public bool TryGetPrompt(string? promptId, out AiPromptRegistration? prompt)
    {
        prompt = null;
        return false;
    }

    /// <inheritdoc />
    public int Count => 0;
}
