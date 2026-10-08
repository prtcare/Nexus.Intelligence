namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The bootstrap register of semantic capability identifiers.
/// </summary>
/// <remarks>
/// <para>
/// <b>These constants are convenience, not authority.</b> The authority is the register — the
/// <see cref="AiCapabilityRegistration"/> records returned by <see cref="AiCapabilityRegister"/> —
/// because the register is data and can be replaced by configuration without shipping a new assembly
/// (W7A Task 12: the <em>schema</em> is code, the <em>membership</em> is configuration). The tests
/// assert that the register and these constants agree, so the two cannot drift apart silently.
/// </para>
/// <para>
/// The nine identifiers here are exactly those named by the W7A directive. Where an earlier freeze
/// used a different name for the same work, the mapping is recorded in
/// <c>W7A_EXISTING_CODE_RECONCILIATION.md</c> and the earlier name is <b>not</b> registered — two
/// identifiers for one capability would make the audit record unable to say which was requested.
/// </para>
/// </remarks>
public static class AiCapabilities
{
    /// <summary>Evaluate a design or change against architecture standards.</summary>
    public const string ArchitectureReview = "architecture.review";

    /// <summary>Review a code change against criteria.</summary>
    public const string CodeReview = "code.review";

    /// <summary>Produce a code change. Supersedes the earlier freeze's <c>coding.implement</c>.</summary>
    public const string CodeGenerate = "code.generate";

    /// <summary>Explain a failing test or build.</summary>
    public const string TestDiagnose = "test.diagnose";

    /// <summary>Condense a document.</summary>
    public const string DocumentSummarize = "document.summarize";

    /// <summary>Analyse business data.</summary>
    public const string BusinessAnalyze = "business.analyze";

    /// <summary>A conversational turn. Supersedes the earlier freeze's <c>conversation.turn</c>.</summary>
    public const string ChatComplete = "chat.complete";

    /// <summary>Produce a vector embedding.</summary>
    public const string EmbeddingGenerate = "embedding.generate";

    /// <summary>Produce an image.</summary>
    public const string ImageGenerate = "image.generate";

    /// <summary>Every identifier this bootstrap register defines.</summary>
    public static IReadOnlyList<string> All { get; } =
    [
        ArchitectureReview,
        CodeReview,
        CodeGenerate,
        TestDiagnose,
        DocumentSummarize,
        BusinessAnalyze,
        ChatComplete,
        EmbeddingGenerate,
        ImageGenerate,
    ];
}

/// <summary>One entry in the capability register.</summary>
/// <remarks>
/// <para>
/// A record rather than a dictionary entry so that the register can be validated as a whole:
/// duplicates, unresolvable dependency classes, missing owners and missing rationales are all
/// detectable at load time rather than at first use under load.
/// </para>
/// <para>
/// <b>There is no model field here, and that is deliberate.</b> What a capability needs of a model —
/// reasoning, long context, a vision channel, a structured-output mode — is model-selection detail,
/// and model selection is the AI Head's internal business. It lives in the AI Head's implementation
/// assemblies, which hold the model-descriptor vocabulary; this assembly is published to Products and
/// must not carry it. A register entry therefore states <em>what the capability is for, how it
/// degrades, and who owns it</em> — the governance facts — and nothing about how it will be served.
/// </para>
/// </remarks>
public sealed record AiCapabilityRegistration
{
    /// <summary>The capability identifier.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>What the capability does, for the register listing. Not a prompt.</summary>
    public required string Description { get; init; }

    /// <summary>
    /// The declared <see cref="AiDependencyClass"/> of the operations that use this capability.
    /// </summary>
    /// <remarks>
    /// Declared here so that "what happens when AI is gone" is answerable from the register rather
    /// than by reading each caller. A capability whose class changes is an architecture change and
    /// must be recorded as one — there is no runtime switch for it.
    /// </remarks>
    public required AiDependencyClass DependencyClass { get; init; }

    /// <summary>The accountable owner of this capability's classification and quality.</summary>
    public required string Owner { get; init; }

    /// <summary>Why the capability has the dependency class it has.</summary>
    public required string DependencyRationale { get; init; }

    /// <summary>True when this entry may be served. A disabled capability is <see cref="AiFailureCategory.CapabilityNotFound"/>.</summary>
    public bool Enabled { get; init; } = true;
}
