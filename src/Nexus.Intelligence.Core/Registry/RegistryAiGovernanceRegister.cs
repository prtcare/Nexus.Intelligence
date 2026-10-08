using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Registry;

/// <summary>
/// The governance register, resolved from the model and provider registry.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the seam W7B specified and left open.</b> Its register contract names the model and
/// provider records as the ones "the model and provider registry supplies", and its
/// <see cref="AiModelGovernanceRecord"/> remarks state that which models exist and which one is picked
/// belongs to "the model registry and router — a different lane's artifact". This type is that supply:
/// it answers the governance engine's questions from the registry rather than from a second store.
/// </para>
/// <para>
/// <b>One record, two read surfaces, and that is the point.</b> An operator writes a model once, with
/// its capability facts and its approval facts together. The router reads the first half through
/// <see cref="IAiModelRegistry"/> and the governance engine reads the second through this type. If the
/// approval facts instead lived in a separate store, an estate would be able to hold a model that
/// routes and is refused — and the disagreement would be invisible, because each half is internally
/// consistent.
/// </para>
/// <para>
/// <b>Agents and prompts were unresolved when W7C shipped, and W7D closed that.</b> The remark this
/// paragraph replaces said they "belong to the agents, tools and context lane; until that lane
/// supplies a register, every execution naming an agent or a prompt is refused". W7D is that lane.
/// The two resource kinds are resolved from the same <see cref="ConfiguredAiRegistry"/> as the models
/// and providers, so an operator writes an agent once and both the pipeline that selects it and the
/// engine that governs it read one record.
/// </para>
/// <para>
/// <b>The refusals did not move; the source of the records did.</b> An agent absent from the registry
/// is still <see cref="AiGovernanceRules.AgentUnregistered"/> and an unapproved one is still
/// <see cref="AiGovernanceRules.AgentNotApproved"/>. What changed is that an estate can now reach a
/// state where those rules do not fire — by registering and approving an agent — instead of there
/// being no possible configuration under which an agent could act.
/// </para>
/// </remarks>
public sealed class RegistryAiGovernanceRegister : IAiGovernanceRegister
{
    private readonly IAiModelRegistry _models;
    private readonly IAiProviderRegistry _providers;
    private readonly IAiAgentRegistry _agents;
    private readonly IAiPromptRegistry _prompts;

    /// <summary>
    /// Projects governance records from the model and provider registries alone.
    /// </summary>
    /// <remarks>
    /// Every agent and prompt resolution fails, and <b>resolution failing is a refusal</b> — so this
    /// overload is not permissive, it is the same fail-closed register narrowed to the two resource
    /// kinds a composition without agent or prompt configuration has. It exists so that a caller
    /// which has no agents and no prompts to declare does not have to name two empty registries to
    /// say so.
    /// </remarks>
    public RegistryAiGovernanceRegister(IAiModelRegistry models, IAiProviderRegistry providers)
        : this(models, providers, EmptyAiAgentRegistry.Instance, EmptyAiPromptRegistry.Instance)
    {
    }

    /// <summary>Projects governance records from all four registries.</summary>
    public RegistryAiGovernanceRegister(
        IAiModelRegistry models,
        IAiProviderRegistry providers,
        IAiAgentRegistry agents,
        IAiPromptRegistry prompts)
    {
        ArgumentNullException.ThrowIfNull(models);
        ArgumentNullException.ThrowIfNull(providers);
        ArgumentNullException.ThrowIfNull(agents);
        ArgumentNullException.ThrowIfNull(prompts);

        _models = models;
        _providers = providers;
        _agents = agents;
        _prompts = prompts;
    }

    /// <inheritdoc />
    /// <remarks>
    /// A model present in the registry with no declared approval projects
    /// <see cref="AiGovernanceApprovalStatus.Unregistered"/> and is refused. That is the intended
    /// reading of an operator who declared a model and did not approve it: the entry says the model
    /// exists, and says nothing about whether it may be used.
    /// </remarks>
    public bool TryResolveModel(string? modelId, out AiModelGovernanceRecord? record)
    {
        record = null;

        if (!_models.TryGetModel(modelId, out var registration) || registration is null)
        {
            return false;
        }

        record = new AiModelGovernanceRecord
        {
            ModelId = registration.ModelId,
            ProviderId = registration.ProviderId,
            Status = registration.Approval,
            MaxClassification = registration.MaxClassification,
            ApprovedBy = registration.ApprovedBy,
            Rationale = registration.GovernanceRationale,
        };

        return true;
    }

    /// <inheritdoc />
    public bool TryResolveProvider(string? providerId, out AiProviderGovernanceRecord? record)
    {
        record = null;

        if (!_providers.TryGetProvider(providerId, out var registration) || registration is null)
        {
            return false;
        }

        record = new AiProviderGovernanceRecord
        {
            ProviderId = registration.ProviderId,
            Status = registration.Approval,
            Trust = registration.Trust,
            PermitsRemoteEgress = registration.PermitsRemoteEgress,
            MaxClassification = registration.MaxClassification,
            Rationale = registration.GovernanceRationale,
        };

        return true;
    }

    /// <inheritdoc />
    /// <remarks>
    /// An agent present in the registry with no declared approval projects
    /// <see cref="AiGovernanceApprovalStatus.Unregistered"/> and is refused — the same reading the
    /// model projection takes, and the same reading an operator who declared an agent and did not
    /// approve it should get: the entry says the agent exists and says nothing about whether it may
    /// act.
    /// </remarks>
    public bool TryResolveAgent(string? agentId, out AiAgentGovernanceRecord? record)
    {
        record = null;

        if (!_agents.TryGetAgent(agentId, out var registration) || registration is null)
        {
            return false;
        }

        record = new AiAgentGovernanceRecord
        {
            AgentId = registration.AgentId,
            Status = registration.Approval,
            AllowedCapabilities = registration.AllowedCapabilities,
            MaxSideEffect = registration.MaxSideEffect,
            Rationale = registration.GovernanceRationale,
        };

        return true;
    }

    /// <inheritdoc />
    /// <remarks>
    /// <b>The prompt body does not appear in the record, and that is not an omission.</b>
    /// <see cref="AiPromptGovernanceRecord"/>'s remarks state why: an audit record and a governance
    /// register are both durable stores, and a prompt body in either is prompt text retained outside
    /// the store that owns it. The registration holds the text; this projection holds the version it
    /// is approved at and the fact of the approval.
    /// </remarks>
    public bool TryResolvePrompt(string? promptId, out AiPromptGovernanceRecord? record)
    {
        record = null;

        if (!_prompts.TryGetPrompt(promptId, out var registration) || registration is null)
        {
            return false;
        }

        record = new AiPromptGovernanceRecord
        {
            PromptId = registration.PromptId,
            ApprovedVersion = registration.Version,
            Status = registration.Approval,
            Owner = registration.Owner,
            Rationale = registration.Rationale,
        };

        return true;
    }
}
