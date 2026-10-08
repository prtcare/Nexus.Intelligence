namespace Nexus.Intelligence.Contracts;

/// <summary>
/// One agent, as the registry states it: what it may act on, what it may act with, and whether it
/// may act at all.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the definition, and it is data.</b> Before W7D an agent was a C# class with a
/// three-member <c>AgentMetadata</c> (<c>Id</c>, <c>Name</c>, <c>Description</c>) and nothing else,
/// registered in the composition root, and the registry that indexed them mapped identifiers to an
/// <c>AgentType</c> enum through a string switch compiled into the assembly. An agent therefore could
/// not be given a prompt, could not be told what tools it was allowed to use, could not be bounded by
/// a data classification, and could not be switched off — none of those fields existed, and adding an
/// agent meant editing the switch and shipping a build. This record is that gap closed: every fact
/// the governance engine asks about an agent is here, written once by an operator.
/// </para>
/// <para>
/// <b>The governance-shaped fields are declarations the register projects from, not a second source
/// of truth</b> — the same arrangement <see cref="AiModelRegistration"/> uses, and for the same
/// reason. A separate approval store would be a second record that can disagree with this one, and
/// the disagreement would surface as an agent that routes and is refused.
/// </para>
/// <para>
/// <b>The defaults all refuse.</b> <see cref="Enabled"/> is false, <see cref="Approval"/> is
/// <see cref="AiGovernanceApprovalStatus.Unregistered"/>, <see cref="MaxClassification"/> is
/// <see cref="DataClassification.Public"/>, <see cref="MaxSideEffect"/> is
/// <see cref="ToolSideEffectClass.None"/> and <see cref="AllowedCapabilities"/> is empty. An entry
/// that declares an agent and nothing else produces an agent that may do nothing — which is the
/// correct reading of an entry that has not said what it is for.
/// </para>
/// </remarks>
public sealed record AiAgentRegistration
{
    /// <summary>The agent identifier. The key the governance register resolves against.</summary>
    /// <remarks>
    /// A free string rather than an enum, matching <see cref="AiModelRegistration.ModelId"/> and for
    /// the same reason: an enum would make adding an agent a compile-time event that forces every
    /// consumer of the published Contracts package to rebuild. The retired <c>AgentType</c> enum is
    /// the worked example — it has five members, one implementation, and a registry that cannot
    /// describe any of them.
    /// </remarks>
    public required string AgentId { get; init; }

    /// <summary>A human-readable name, for reports and for the system frame. Never used to decide anything.</summary>
    public required string DisplayName { get; init; }

    /// <summary>What this agent is for, in an operator's words. Required, so no agent arrives unexplained.</summary>
    public required string Purpose { get; init; }

    /// <summary>
    /// The capabilities this agent is approved to serve. Empty means none.
    /// </summary>
    /// <remarks>
    /// An allow-list and not a ceiling, because an agent's authority is a grant of specific work
    /// rather than a bound on a spectrum — the reading <see cref="AiAgentGovernanceRecord"/> already
    /// gives. The failure mode of an omission here is a request refused, which is the direction an
    /// omission should fail in.
    /// </remarks>
    public IReadOnlyList<CapabilityId> AllowedCapabilities { get; init; } = [];

    /// <summary>The tool identifiers this agent may use. Empty means it may use no tools.</summary>
    /// <remarks>
    /// An allow-list rather than a ceiling, for the reason <see cref="AllowedCapabilities"/> gives:
    /// a tool an agent may use is a grant. The side-effect ceiling below bounds <em>how far</em> a
    /// granted tool may reach; this list bounds <em>which</em> tools are in reach at all. Both
    /// apply, and <see cref="DeterministicAiGovernanceEvaluator"/> refuses when either is exceeded.
    /// </remarks>
    public IReadOnlyList<string> AllowedToolIds { get; init; } = [];

    /// <summary>
    /// The most sensitive classification this agent may draw on, as a ceiling.
    /// </summary>
    /// <remarks>
    /// A ceiling and not a list, following <see cref="AiModelGovernanceRecord.MaxClassification"/>
    /// rather than the allow-list shape used above. The asymmetry is deliberate: an omission from an
    /// allow-list refuses more, an omission from a ceiling permits more, so the two questions get the
    /// shape that fails in the safe direction for each. A classification an agent is permitted to
    /// read is a bound, and a list of permitted classifications would let a newly added member be
    /// silently absent from every agent's grant.
    /// </remarks>
    public DataClassification MaxClassification { get; init; } = DataClassification.Public;

    /// <summary>
    /// The prompt or instruction set this agent operates under, where it has one.
    /// </summary>
    /// <remarks>
    /// A reference and not text. The body belongs to the prompt registry, which is where a version
    /// is recorded and an approval is written; an agent that carried its own instruction text would
    /// be an instruction set with no version, no owner and no review — the arrangement
    /// <see cref="AiPromptGovernanceRecord"/> exists to make impossible.
    /// </remarks>
    public string? PromptId { get; init; }

    /// <summary>The least reasoning class this agent's work needs. <see cref="AiReasoningClass.None"/> means no requirement.</summary>
    public AiReasoningClass RequiredReasoning { get; init; } = AiReasoningClass.None;

    /// <summary>
    /// The most severe tool side effect this agent may cause, whatever tool it is granted.
    /// </summary>
    /// <remarks>
    /// The second of the two ceilings described on <see cref="AllowedToolIds"/>. Defaults to
    /// <see cref="ToolSideEffectClass.None"/>, so an agent that has not been assessed may read
    /// nothing and cause nothing.
    /// </remarks>
    public ToolSideEffectClass MaxSideEffect { get; init; } = ToolSideEffectClass.None;

    /// <summary>
    /// How the work this agent does is classified as an AI dependency.
    /// </summary>
    /// <remarks>
    /// <see cref="AiDependencyClass.AiProhibited"/> is <b>not</b> a fourth point on a scale of
    /// availability — it means there is no AI path here at all, degraded or otherwise. An agent
    /// declared prohibited is refused by <see cref="AiGovernanceRules.AgentNotApproved"/> through its
    /// approval status; this field records the class so that "the estate has decided this work is not
    /// AI's" is readable from the registry rather than inferred from an absent entry.
    /// </remarks>
    public AiDependencyClass GovernanceClass { get; init; } = AiDependencyClass.AiOptional;

    /// <summary>Whether an operator has switched this agent on. Defaults to off.</summary>
    public bool Enabled { get; init; }

    /// <summary>Whether the agent has been approved to act.</summary>
    public AiGovernanceApprovalStatus Approval { get; init; } = AiGovernanceApprovalStatus.Unregistered;

    /// <summary>Who approved it. Required for an approval to be reviewable.</summary>
    public string? ApprovedBy { get; init; }

    /// <summary>Why it is in the state it is in. Required, so no entry arrives without a reason.</summary>
    public required string GovernanceRationale { get; init; }

    /// <summary>True when this agent is switched on and approved to act.</summary>
    /// <remarks>
    /// A convenience for the composition root's own validation, never a substitute for the governance
    /// engine's reading of the two fields. The engine resolves the record and applies
    /// <see cref="AiGovernanceRules.AgentNotApproved"/> itself, so a caller that reasoned from this
    /// property would be re-implementing a governance decision in the wrong place.
    /// </remarks>
    public bool IsActable => Enabled && Approval is AiGovernanceApprovalStatus.Approved;

    /// <summary>True when this agent may serve the capability.</summary>
    public bool Declares(CapabilityId capability)
    {
        ArgumentNullException.ThrowIfNull(capability);

        return AllowedCapabilities.Contains(capability);
    }
}

/// <summary>
/// The agents that exist, and what each of them is.
/// </summary>
/// <remarks>
/// <para>
/// <b>The one authoritative agent registry.</b> The governance engine asks it, the turn pipeline
/// selects from it, and nothing else holds agent definitions. There is deliberately no enumeration
/// method — the same absence <see cref="IAiGovernanceRegister"/> has and for the same reason: a
/// registry that can be listed is a registry whose contents something will eventually copy into a
/// second list, and the second list is the one that goes stale.
/// </para>
/// <para>
/// <b>Resolution is the only question asked of it, and an unknown identifier resolves to nothing.</b>
/// The caller treats that as <see cref="AiGovernanceApprovalStatus.Unregistered"/>, which is a
/// refusal. An agent nobody registered is not an agent that may act by default.
/// </para>
/// </remarks>
public interface IAiAgentRegistry
{
    /// <summary>Resolves an agent's registration, or returns <see langword="false"/> when nothing is registered under that identifier.</summary>
    bool TryGetAgent(string? agentId, out AiAgentRegistration? agent);

    /// <summary>How many agents are registered. For composition assertions, not for enumeration.</summary>
    int Count { get; }
}

/// <summary>The registry that knows no agents: the state before any agent has been registered.</summary>
/// <remarks>
/// <b>This is the default, and it refuses everything.</b> It is the correct state of an estate in
/// which no agent has been through a governance approval, and it is deliberately not a placeholder
/// to be replaced at leisure. A registry that permitted by default would make "nobody has registered
/// this yet" indistinguishable from "this may act", and the first request after a deploy would be
/// the one that found out.
/// </remarks>
public sealed class EmptyAiAgentRegistry : IAiAgentRegistry
{
    /// <summary>The single instance. The registry is stateless.</summary>
    public static EmptyAiAgentRegistry Instance { get; } = new();

    /// <inheritdoc />
    public bool TryGetAgent(string? agentId, out AiAgentRegistration? agent)
    {
        agent = null;
        return false;
    }

    /// <inheritdoc />
    public int Count => 0;
}
