namespace Nexus.Intelligence.Contracts;

/// <summary>The governance domains AI Governance decides over.</summary>
/// <remarks>
/// <para>
/// One value per domain the W7B directive names. The vocabulary exists so that a
/// <see cref="AiGovernanceDecision"/> can say <em>which</em> domain refused, and so that an escalation
/// rule can be scoped to a domain without restating the rule table.
/// </para>
/// <para>
/// <see cref="Model"/> and <see cref="Provider"/> are separate values even though a model always has a
/// provider, because the two are approved by different criteria: a model is approved for what it can
/// do, a provider for where the content goes. A single value would force one rationale to answer both
/// questions, which is how a provider approval silently becomes a model approval.
/// </para>
/// </remarks>
public enum AiGovernanceSubject
{
    /// <summary>Which models may serve an execution.</summary>
    Model = 0,

    /// <summary>Which providers may receive content, and on what terms.</summary>
    Provider = 1,

    /// <summary>Which AI agents may act, and for which capabilities.</summary>
    Agent = 2,

    /// <summary>Which tools may be invoked, and to what depth of effect.</summary>
    Tool = 3,

    /// <summary>Which prompts and instruction sets may be applied, at which version.</summary>
    Prompt = 4,

    /// <summary>What content may leave, for where, and after what treatment.</summary>
    DataExposure = 5,

    /// <summary>Whether the requester may draw on the context it supplied.</summary>
    ContextPermission = 6,

    /// <summary>What the execution may cost.</summary>
    Cost = 7,

    /// <summary>Provider trust, egress permission and classification ceilings.</summary>
    Security = 8,

    /// <summary>Whether the output can be evidenced against the caller's quality requirement.</summary>
    Evaluation = 9,

    /// <summary>A protected surface on which AI participation is forbidden outright.</summary>
    ProhibitedSurface = 10,
}

/// <summary>How a governed resource — a model, provider, agent or prompt — stands.</summary>
/// <remarks>
/// <see cref="Unregistered"/> is the value an absent record reports, and it is a refusal. It is a
/// member of this enum rather than the absence of a record so that "nothing is registered for this
/// identifier" is a first-class answer with a name, an audit entry and a rule that fires — rather than
/// a null a caller might read as "no objection".
/// </remarks>
public enum AiGovernanceApprovalStatus
{
    /// <summary>Nothing is registered under this identifier. AI participation is refused.</summary>
    Unregistered = 0,

    /// <summary>Registered and approved for use.</summary>
    Approved = 1,

    /// <summary>Registered but suspended. Refused until a named person restores it.</summary>
    Suspended = 2,

    /// <summary>Registered but retired. Refused permanently; the record is kept for the audit trail.</summary>
    Retired = 3,
}

/// <summary>
/// How far a provider is trusted with content, as a governed fact.
/// </summary>
/// <remarks>
/// <para>
/// Ordered, because a policy states a <em>floor</em> and the comparison is the rule:
/// <see cref="AiGovernancePolicy.MinimumTrustForRemoteEgress"/> is a floor, and a provider below it may
/// not receive content over the network whatever else permits it.
/// </para>
/// <para>
/// <b>This is not a vendor ranking.</b> No member names a provider; which provider sits at which tier
/// is a record in the register, and the tier vocabulary is the same whether the estate runs two
/// providers or twenty.
/// </para>
/// </remarks>
public enum AiProviderTrustTier
{
    /// <summary>Not assessed. Treated as untrusted, which is the same as refused for remote egress.</summary>
    Untrusted = 0,

    /// <summary>Assessed, and permitted only for material at or below the tier's classification ceiling.</summary>
    Restricted = 1,

    /// <summary>Assessed and approved for the classifications its record permits.</summary>
    Approved = 2,

    /// <summary>Runs on infrastructure the operator controls. No network egress leaves the estate.</summary>
    Sovereign = 3,
}

/// <summary>What is known about one model, as a governance fact.</summary>
/// <remarks>
/// <para>
/// <b>A register record, not a routing entry.</b> Nothing here selects a model; the record is consulted
/// <em>after</em> selection to decide whether the selection may proceed. Which models exist, and which
/// one is picked for a piece of work, belongs to the model registry and router — a different lane's
/// artifact. This type is where that lane's output is <em>governed</em>.
/// </para>
/// <para>
/// <see cref="MaxClassification"/> is a ceiling and not a list, for the reason
/// <see cref="ToolPermissionProfile.MaxSideEffect"/> gives: a list's failure mode is that a newly
/// registered thing is permitted by omission.
/// </para>
/// </remarks>
public sealed record AiModelGovernanceRecord
{
    /// <summary>The model identifier, as the model registry states it.</summary>
    public required string ModelId { get; init; }

    /// <summary>The provider that serves it.</summary>
    public required string ProviderId { get; init; }

    /// <summary>Whether the model may be used.</summary>
    public required AiGovernanceApprovalStatus Status { get; init; }

    /// <summary>The most sensitive classification this model is cleared to receive.</summary>
    public DataClassification MaxClassification { get; init; } = DataClassification.Public;

    /// <summary>Who approved it, where it is approved. Required for an approval to be reviewable.</summary>
    public string? ApprovedBy { get; init; }

    /// <summary>Why it is in the state it is in.</summary>
    public required string Rationale { get; init; }
}

/// <summary>What is known about one provider, as a governance fact.</summary>
public sealed record AiProviderGovernanceRecord
{
    /// <summary>The provider identifier, as the model registry states it.</summary>
    public required string ProviderId { get; init; }

    /// <summary>Whether the provider may be used.</summary>
    public required AiGovernanceApprovalStatus Status { get; init; }

    /// <summary>How far the provider is trusted with content.</summary>
    public AiProviderTrustTier Trust { get; init; } = AiProviderTrustTier.Untrusted;

    /// <summary>True when content may reach this provider over the network at all.</summary>
    public bool PermitsRemoteEgress { get; init; }

    /// <summary>
    /// The most sensitive classification this provider is cleared to receive.
    /// </summary>
    /// <remarks>
    /// Separate from the model's ceiling and both are applied. A provider cleared for
    /// <see cref="DataClassification.CustomerData"/> serving a model cleared only for
    /// <see cref="DataClassification.Internal"/> must refuse customer data — the narrower clearance
    /// wins, because the model does not stop the content reaching the provider.
    /// </remarks>
    public DataClassification MaxClassification { get; init; } = DataClassification.Public;

    /// <summary>Why it is in the state it is in.</summary>
    public required string Rationale { get; init; }
}

/// <summary>What is known about one agent, as a governance fact.</summary>
public sealed record AiAgentGovernanceRecord
{
    /// <summary>The agent identifier.</summary>
    public required string AgentId { get; init; }

    /// <summary>Whether the agent may act.</summary>
    public required AiGovernanceApprovalStatus Status { get; init; }

    /// <summary>
    /// The capabilities the agent is approved to serve. Empty means none.
    /// </summary>
    /// <remarks>
    /// An allow-list and not a ceiling, because an agent's authority is a grant of specific work rather
    /// than a bound on a spectrum. The failure mode of an omission here is a request refused, which is
    /// the direction an omission should fail in.
    /// </remarks>
    public IReadOnlyList<CapabilityId> AllowedCapabilities { get; init; } = [];

    /// <summary>The most severe tool side effect this agent may cause.</summary>
    public ToolSideEffectClass MaxSideEffect { get; init; } = ToolSideEffectClass.None;

    /// <summary>Why it is in the state it is in.</summary>
    public required string Rationale { get; init; }
}

/// <summary>What is known about one prompt or instruction set, as a governance fact.</summary>
/// <remarks>
/// <para>
/// A prompt is a governed artifact for one reason above the others: it is the artefact that most
/// directly steers what the model does, and it is the one most likely to be edited in place. Requiring
/// a version is what makes an execution reproducible; requiring an approval is what makes the edit a
/// reviewable act.
/// </para>
/// <para>
/// The prompt <em>text</em> is deliberately absent, and is not merely omitted here: an audit record and
/// a governance register are both durable stores, and a prompt body in either is prompt text retained
/// outside the store that owns it. This record states that a prompt exists, who owns it, and whether
/// it may run.
/// </para>
/// </remarks>
public sealed record AiPromptGovernanceRecord
{
    /// <summary>The prompt or instruction set identifier.</summary>
    public required string PromptId { get; init; }

    /// <summary>The version that is approved. An execution naming a different version is refused.</summary>
    public required string ApprovedVersion { get; init; }

    /// <summary>Whether the prompt may be applied.</summary>
    public required AiGovernanceApprovalStatus Status { get; init; }

    /// <summary>The accountable owner.</summary>
    public required string Owner { get; init; }

    /// <summary>Why it is in the state it is in.</summary>
    public required string Rationale { get; init; }
}

/// <summary>
/// The governed resources AI Governance decides about.
/// </summary>
/// <remarks>
/// <para>
/// <b>A port, and the only place membership lives.</b> The directive requires registries and policy
/// records rather than hardcoded provider and model lists; this interface is that registry's read
/// surface, and the evaluator holds no model, provider, agent or prompt identifier of its own. The
/// implementation is supplied by the lane that owns each resource — the model and provider registry
/// supplies the first two, the agents and tools lane supplies the third — and the governance engine
/// only ever asks.
/// </para>
/// <para>
/// Every method returns <see langword="false"/> for an unknown identifier, and the evaluator treats
/// that as <see cref="AiGovernanceApprovalStatus.Unregistered"/> — a refusal. There is deliberately no
/// "list everything" method: the engine never enumerates the register, it only resolves against it, so
/// a register implementation cannot be asked a question whose answer it would have to materialise.
/// </para>
/// </remarks>
public interface IAiGovernanceRegister
{
    /// <summary>Resolves a model's governance record.</summary>
    bool TryResolveModel(string? modelId, out AiModelGovernanceRecord? record);

    /// <summary>Resolves a provider's governance record.</summary>
    bool TryResolveProvider(string? providerId, out AiProviderGovernanceRecord? record);

    /// <summary>Resolves an agent's governance record.</summary>
    bool TryResolveAgent(string? agentId, out AiAgentGovernanceRecord? record);

    /// <summary>Resolves a prompt's governance record.</summary>
    bool TryResolvePrompt(string? promptId, out AiPromptGovernanceRecord? record);
}

/// <summary>
/// The register that knows nothing: the state before any resource has been approved.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the default, and it refuses everything.</b> It is not a placeholder to be replaced at
/// leisure — it is the correct state of an estate in which no model, provider, agent or prompt has
/// been through a governance approval. Every resolution fails, every governed resource reports
/// <see cref="AiGovernanceApprovalStatus.Unregistered"/>, and every execution that names one is
/// blocked.
/// </para>
/// <para>
/// That is a deliberate choice about which way the default fails. A register that permitted by
/// default would make "nobody has approved this yet" indistinguishable from "this is approved", and
/// the first execution after a deploy would be the one that found out. A default that refuses produces
/// a loud, deterministic, immediately-diagnosable block instead — and the remedy is to write the
/// approval, which is the act the governance model exists to require.
/// </para>
/// </remarks>
public sealed class EmptyAiGovernanceRegister : IAiGovernanceRegister
{
    /// <summary>The single instance. The register is stateless.</summary>
    public static EmptyAiGovernanceRegister Instance { get; } = new();

    /// <inheritdoc />
    public bool TryResolveModel(string? modelId, out AiModelGovernanceRecord? record)
    {
        record = null;
        return false;
    }

    /// <inheritdoc />
    public bool TryResolveProvider(string? providerId, out AiProviderGovernanceRecord? record)
    {
        record = null;
        return false;
    }

    /// <inheritdoc />
    public bool TryResolveAgent(string? agentId, out AiAgentGovernanceRecord? record)
    {
        record = null;
        return false;
    }

    /// <inheritdoc />
    public bool TryResolvePrompt(string? promptId, out AiPromptGovernanceRecord? record)
    {
        record = null;
        return false;
    }
}
