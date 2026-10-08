namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The instruction set identifiers the AI Head itself dispatches under.
/// </summary>
/// <remarks>
/// <para>
/// <b>These are keys, not instruction text.</b> The text lives in the prompt registry, where it is
/// versioned, owned and approved; a constant here only names which registered set a built-in execution
/// asks for. That is the same arrangement <see cref="AiCapabilities"/> has with the capability register:
/// a stable identifier in code, and everything about what it means supplied as data.
/// </para>
/// <para>
/// <b>Why constants at all, when the directive prefers registries over hardcoded lists.</b> The directive
/// forbids hardcoded <em>membership</em> — the list of what exists. An identifier a built-in execution
/// asks for is not membership: it is a call site saying which instruction set it needs, and a call site
/// cannot name a prompt by reading configuration, because it is the thing that has to ask. What matters
/// is that naming one of these grants nothing: an estate whose registry does not hold the identifier
/// refuses the execution as <see cref="AiGovernanceRules.PromptUnregistered"/>, and one that holds it
/// unapproved refuses as <see cref="AiGovernanceRules.PromptNotApproved"/>.
/// </para>
/// <para>
/// <b>An entry here is a promise that the estate is expected to register it.</b> These are the
/// instruction sets whose absence makes a live endpoint stop working, and they are listed in one place so
/// that the configuration an operator has to write is discoverable from the code rather than from a
/// production refusal.
/// </para>
/// </remarks>
public static class AiPrompts
{
    /// <summary>
    /// The instruction set the plan endpoint decomposes an objective under.
    /// </summary>
    /// <remarks>
    /// This text used to be a three-line C# string literal inside <c>Planner</c>, and it was the clearest
    /// case in the estate of an instruction set that could not be reviewed: it decided the shape of every
    /// plan the product produced, and changing it required a rebuild and a release. Moving it here — the
    /// identifier, not the text — is what lets an operator change it, version it, and be asked to approve
    /// it before it takes effect.
    /// </remarks>
    public const string PlanDecomposition = "prompt.plan.decomposition";

    /// <summary>
    /// The instruction set a conversational turn runs under when it names no agent.
    /// </summary>
    /// <remarks>
    /// The default instruction set for the live turn path. A turn whose agent names its own instruction
    /// set uses that one instead; this is what an execution with no agent applies.
    /// </remarks>
    public const string ConversationTurn = "prompt.conversation.turn";
}
