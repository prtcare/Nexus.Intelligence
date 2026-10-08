using System.Globalization;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Registry;

/// <summary>
/// The registry as configured: models, providers and declared health, parsed once and read many times.
/// </summary>
/// <remarks>
/// <para>
/// <b>Parsed in the constructor, so a malformed registry fails at composition and not on a request.</b>
/// An estate whose configuration names a capability that does not exist, or a health state that is not
/// a member, has a defect that is knowable before it serves anything. Deferring the discovery to the
/// first request that happens to touch the bad entry would surface it as a routing refusal with no
/// indication that the cause was a typo in a different file, and the person paged would be looking at
/// the wrong artefact.
/// </para>
/// <para>
/// <b>Structural defects fail the load; referential ones do not.</b> A duplicate model identifier, a
/// blank rationale, a malformed capability, a secret reference shaped like a key — these are
/// malformations with no defensible reading, and the load refuses them. A model naming a provider that
/// is not registered is different: it has a defensible reading (the provider is not available here),
/// and the router expresses it as a named <see cref="AiRoutingRejectionReason.ProviderNotRegistered"/>
/// on that model's rejection. Refusing the whole estate because one model's provider is absent would
/// take every other capability down with it, which is a worse answer than routing around it and
/// saying so.
/// </para>
/// <para>
/// <b>Immutable after construction.</b> The three ports it implements are read-only, and nothing in
/// the estate can add a model or approve a provider at runtime. That is deliberate for this lane: a
/// registry that could be edited in flight would make a routing decision depend on when it ran, and
/// this lane's central claim is that the same inputs produce the same outcome.
/// </para>
/// </remarks>
public sealed class ConfiguredAiRegistry :
    IAiModelRegistry,
    IAiProviderRegistry,
    IAiModelHealthSource,
    IAiAgentRegistry,
    IAiToolRegistry,
    IAiPromptRegistry
{
    private readonly Dictionary<string, AiProviderRegistration> _providers;
    private readonly Dictionary<string, AiModelRegistration> _models;
    private readonly Dictionary<CapabilityId, IReadOnlyList<AiModelRegistration>> _modelsByCapability;
    private readonly Dictionary<string, AiModelHealthState> _providerHealth;
    private readonly Dictionary<(string ModelId, string ProviderId), AiModelHealthState> _modelHealth;
    private readonly Dictionary<string, AiAgentRegistration> _agents;
    private readonly Dictionary<string, AiToolRegistration> _tools;
    private readonly IReadOnlyList<AiGovernanceToolRule> _toolRules;
    private readonly Dictionary<string, AiPromptRegistration> _prompts;

    /// <summary>Parses and validates a registry configuration.</summary>
    /// <exception cref="InvalidOperationException">
    /// The configuration contains a structural defect. The message names the offending entry.
    /// </exception>
    public ConfiguredAiRegistry(AiRegistryConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);

        _providers = BuildProviders(configuration.Providers);
        _models = BuildModels(configuration.Models);
        _modelsByCapability = IndexByCapability(_models.Values);
        (var providerHealth, var modelHealth) = BuildHealth(configuration.Health);
        _providerHealth = providerHealth;
        _modelHealth = modelHealth;

        // W7D: the three resource kinds W7C did not own, parsed by the same type from the same
        // section. They are parsed here rather than in a registry of their own for the reason the
        // model and provider halves are in one type: an operator writes the estate's AI resources in
        // one file, and a second registry would be a second parse of one artefact with its own
        // failure modes and its own idea of what a valid entry is.
        _agents = BuildAgents(configuration.Agents);
        _tools = BuildTools(configuration.Tools);

        // Projected once, here, so the governance policy table and the tool registry cannot describe
        // the same tool differently. See IAiToolRegistry.GovernanceRules.
        _toolRules = _tools.Values
            .OrderBy(tool => tool.ToolId, StringComparer.Ordinal)
            .Select(tool => new AiGovernanceToolRule
            {
                RuleId = $"tool.{tool.ToolId}",
                ToolId = tool.ToolId,
                SideEffect = tool.SideEffect,
                RequiresHumanApproval = tool.RequiresHumanApproval,
                Rationale = tool.Rationale,
            })
            .ToArray();

        _prompts = BuildPrompts(configuration.Prompts);
    }

    /// <summary>An estate with nothing registered, which routes nothing.</summary>
    /// <remarks>
    /// The state before any configuration has been written. Every capability lookup returns nothing,
    /// every resolution fails, and every route is refused — which is the correct answer for a registry
    /// that has been told about no models, and the reason it is safe to ship as the default.
    /// </remarks>
    public static ConfiguredAiRegistry Empty { get; } = new(new AiRegistryConfiguration());

    /// <inheritdoc />
    public int Count => _models.Count;

    /// <inheritdoc />
    int IAiProviderRegistry.Count => _providers.Count;

    /// <inheritdoc />
    /// <remarks>
    /// Ordered by model identifier, ordinally. See the interface for why the order is contractual: the
    /// ranker's tie-breakers are explicit, but a non-deterministic seed order would make the whole
    /// outcome non-deterministic through a tie-break nobody wrote down.
    /// </remarks>
    public IReadOnlyList<AiModelRegistration> ListForCapability(CapabilityId capability)
    {
        ArgumentNullException.ThrowIfNull(capability);

        return _modelsByCapability.TryGetValue(capability, out var models) ? models : [];
    }

    /// <inheritdoc />
    public bool TryGetModel(string? modelId, out AiModelRegistration? registration)
    {
        if (string.IsNullOrEmpty(modelId))
        {
            registration = null;
            return false;
        }

        return _models.TryGetValue(modelId, out registration);
    }

    /// <inheritdoc />
    public bool TryGetProvider(string? providerId, out AiProviderRegistration? registration)
    {
        if (string.IsNullOrEmpty(providerId))
        {
            registration = null;
            return false;
        }

        return _providers.TryGetValue(providerId, out registration);
    }

    /// <inheritdoc />
    /// <remarks>
    /// A model-scoped declaration wins over a provider-wide one, because the narrower statement is the
    /// more specific claim and the one an operator had to write deliberately. A route with neither
    /// reports <see cref="AiModelHealthState.Unknown"/>, which is not routable.
    /// </remarks>
    public AiModelHealthState GetModelHealth(string modelId, string providerId)
        => _modelHealth.TryGetValue((modelId, providerId), out var state)
            ? state
            : AiModelHealthState.Unknown;

    /// <inheritdoc />
    public AiModelHealthState GetProviderHealth(string providerId)
        => _providerHealth.TryGetValue(providerId, out var state) ? state : AiModelHealthState.Unknown;

    // --- W7D: agents, tools and prompts -------------------------------------------------------------

    /// <inheritdoc />
    int IAiAgentRegistry.Count => _agents.Count;

    /// <inheritdoc />
    public bool TryGetAgent(string? agentId, out AiAgentRegistration? agent)
    {
        if (string.IsNullOrEmpty(agentId))
        {
            agent = null;
            return false;
        }

        return _agents.TryGetValue(agentId, out agent);
    }

    /// <inheritdoc />
    int IAiToolRegistry.Count => _tools.Count;

    /// <inheritdoc />
    public bool TryGetTool(string? toolId, out AiToolRegistration? tool)
    {
        if (string.IsNullOrEmpty(toolId))
        {
            tool = null;
            return false;
        }

        return _tools.TryGetValue(toolId, out tool);
    }

    /// <inheritdoc />
    public IReadOnlyList<AiGovernanceToolRule> GovernanceRules => _toolRules;

    /// <inheritdoc />
    int IAiPromptRegistry.Count => _prompts.Count;

    /// <inheritdoc />
    public bool TryGetPrompt(string? promptId, out AiPromptRegistration? prompt)
    {
        if (string.IsNullOrEmpty(promptId))
        {
            prompt = null;
            return false;
        }

        return _prompts.TryGetValue(promptId, out prompt);
    }

    // --- Parsing ------------------------------------------------------------------------------------

    private static Dictionary<string, AiProviderRegistration> BuildProviders(
        List<AiProviderConfigurationEntry> entries)
    {
        var providers = new Dictionary<string, AiProviderRegistration>(StringComparer.Ordinal);

        for (var index = 0; index < entries.Count; index++)
        {
            var path = $"Providers[{index}]";
            var entry = entries[index];

            var providerId = Required(entry.ProviderId, path, "ProviderId");
            var secretReference = entry.SecretReference;

            // A reference that is present but not shaped like a name is refused rather than stored.
            // This is the only place a credential-shaped string could enter the registry, so it is the
            // only place the check has to hold.
            if (!string.IsNullOrWhiteSpace(secretReference)
                && !AiProviderRegistration.IsWellFormedSecretReference(secretReference))
            {
                throw new InvalidOperationException(
                    $"{path}: SecretReference '{secretReference}' is not shaped like an environment-variable "
                    + "name. The registry stores the NAME of the variable holding a credential and never a "
                    + "value; if a credential value was pasted here, remove it and rotate it.");
            }

            var weight = entry.Weight ?? 1.0;

            // A weight multiplies the ranking score, so a negative one would invert the operator's own
            // preference: the route they ranked highest would sort last. Silent inversion is worse than
            // a refusal, because the estate still routes and still looks healthy.
            if (weight < 0)
            {
                throw new InvalidOperationException(
                    $"{path}: Weight {weight} is negative. A weight scales preference in the ranking and "
                    + "cannot be less than zero; use a negative priority to express deprioritisation.");
            }

            var registration = new AiProviderRegistration
            {
                ProviderId = providerId,
                DisplayName = Required(entry.DisplayName, path, "DisplayName"),
                AdapterIdentity = Required(entry.AdapterIdentity, path, "AdapterIdentity"),
                Capabilities = ParseCapabilities(entry.Capabilities, path),
                Enabled = entry.Enabled,
                SecretReference = string.IsNullOrWhiteSpace(secretReference) ? null : secretReference.Trim(),
                PermitsRemoteEgress = entry.PermitsRemoteEgress,
                Trust = ParseEnum(entry.Trust, AiProviderTrustTier.Untrusted, path, "trust tier"),
                Priority = entry.Priority,
                Weight = weight,
                Approval = ParseEnum(entry.Approval, AiGovernanceApprovalStatus.Unregistered, path, "approval status"),
                MaxClassification = ParseEnum(
                    entry.MaxClassification, DataClassification.Public, path, "classification"),
                ApprovedBy = entry.ApprovedBy,
                GovernanceRationale = Required(entry.GovernanceRationale, path, "GovernanceRationale"),
            };

            if (!providers.TryAdd(providerId, registration))
            {
                throw new InvalidOperationException(
                    $"{path}: provider '{providerId}' is declared more than once. Two entries for one "
                    + "identity would make every decision that names it ambiguous.");
            }
        }

        return providers;
    }

    private static Dictionary<string, AiModelRegistration> BuildModels(List<AiModelConfigurationEntry> entries)
    {
        var models = new Dictionary<string, AiModelRegistration>(StringComparer.Ordinal);

        for (var index = 0; index < entries.Count; index++)
        {
            var path = $"Models[{index}]";
            var entry = entries[index];

            var modelId = Required(entry.ModelId, path, "ModelId");

            var registration = new AiModelRegistration
            {
                ModelId = modelId,
                ProviderId = Required(entry.ProviderId, path, "ProviderId"),
                DisplayName = Required(entry.DisplayName, path, "DisplayName"),
                Capabilities = ParseCapabilities(entry.Capabilities, path),
                MaxContextTokens = entry.MaxContextTokens,
                MaxOutputTokens = entry.MaxOutputTokens,
                InputModalities = ParseModalities(entry.InputModalities, path, "InputModalities"),
                OutputModalities = ParseModalities(entry.OutputModalities, path, "OutputModalities"),
                Reasoning = ParseEnum(entry.Reasoning, AiReasoningClass.None, path, "reasoning class"),
                RelativeSpeed = ParseEnum(entry.RelativeSpeed, AiRelativeSpeed.Unknown, path, "speed class"),
                Availability = ParseEnum(
                    entry.Availability, AiModelAvailability.Unknown, path, "availability state"),
                Enabled = entry.Enabled,
                CostMetadataReference = entry.CostMetadataReference,
                InputCostPer1kTokens = entry.InputCostPer1kTokens,
                OutputCostPer1kTokens = entry.OutputCostPer1kTokens,
                CostCurrency = string.IsNullOrWhiteSpace(entry.CostCurrency) ? null : entry.CostCurrency.Trim(),
                PriceStatus = ParseEnum(entry.PriceStatus, AiPricingStatus.Current, path, "pricing status"),
                PriceEffectiveFrom = ParseDate(entry.PriceEffectiveFrom, path, "PriceEffectiveFrom"),
                PriceEffectiveTo = ParseDate(entry.PriceEffectiveTo, path, "PriceEffectiveTo"),
                ProcessingTiers = ParseTiers(entry.ProcessingTiers, path),
                Approval = ParseEnum(entry.Approval, AiGovernanceApprovalStatus.Unregistered, path, "approval status"),
                MaxClassification = ParseEnum(
                    entry.MaxClassification, DataClassification.Public, path, "classification"),
                ApprovedBy = entry.ApprovedBy,
                GovernanceRationale = Required(entry.GovernanceRationale, path, "GovernanceRationale"),
            };

            if (!models.TryAdd(modelId, registration))
            {
                throw new InvalidOperationException(
                    $"{path}: model '{modelId}' is declared more than once. The identifier is half of the "
                    + "governance key, so a duplicate would make an approval ambiguous.");
            }
        }

        return models;
    }

    private static Dictionary<CapabilityId, IReadOnlyList<AiModelRegistration>> IndexByCapability(
        IEnumerable<AiModelRegistration> models)
    {
        var index = new Dictionary<CapabilityId, List<AiModelRegistration>>();

        // Ordered input, ordered output: the models dictionary is not ordered, so the sort below is
        // what makes ListForCapability deterministic rather than merely usually-stable.
        foreach (var model in models.OrderBy(m => m.ModelId, StringComparer.Ordinal))
        {
            foreach (var capability in model.Capabilities)
            {
                if (!index.TryGetValue(capability, out var bucket))
                {
                    bucket = [];
                    index[capability] = bucket;
                }

                bucket.Add(model);
            }
        }

        return index.ToDictionary(
            pair => pair.Key,
            pair => (IReadOnlyList<AiModelRegistration>)pair.Value.ToArray());
    }

    private static (Dictionary<string, AiModelHealthState> Provider,
                    Dictionary<(string, string), AiModelHealthState> Model) BuildHealth(
        List<AiHealthConfigurationEntry> entries)
    {
        var providerHealth = new Dictionary<string, AiModelHealthState>(StringComparer.Ordinal);
        var modelHealth = new Dictionary<(string, string), AiModelHealthState>();

        for (var index = 0; index < entries.Count; index++)
        {
            var path = $"Health[{index}]";
            var entry = entries[index];

            var providerId = Required(entry.ProviderId, path, "ProviderId");
            var state = ParseEnum(entry.State, AiModelHealthState.Unknown, path, "health state");

            if (string.IsNullOrWhiteSpace(entry.ModelId))
            {
                if (!providerHealth.TryAdd(providerId, state))
                {
                    throw new InvalidOperationException(
                        $"{path}: provider '{providerId}' has more than one provider-wide health entry.");
                }
            }
            else if (!modelHealth.TryAdd((entry.ModelId.Trim(), providerId), state))
            {
                throw new InvalidOperationException(
                    $"{path}: model '{entry.ModelId}' on provider '{providerId}' has more than one "
                    + "health entry.");
            }
        }

        return (providerHealth, modelHealth);
    }

    // --- W7D parsers --------------------------------------------------------------------------------

    /// <summary>
    /// Parses the agent declarations.
    /// </summary>
    /// <remarks>
    /// <b>A structural defect fails the load; a referential one does not.</b> A blank identifier, a
    /// duplicated one, a malformed capability or a missing rationale are malformations with no
    /// defensible reading. An agent naming a <c>PromptId</c> that no prompt entry declares is
    /// different: it has a defensible reading — the instruction set is not registered here — and the
    /// governance engine expresses it as <see cref="AiGovernanceRules.PromptUnregistered"/> when the
    /// execution names it, which is the same refusal an unregistered prompt gets from any other
    /// caller. Refusing the whole estate because one agent's prompt is absent would take every other
    /// capability down with it, which is the worse answer.
    /// </remarks>
    private static Dictionary<string, AiAgentRegistration> BuildAgents(
        List<AiAgentConfigurationEntry> entries)
    {
        var agents = new Dictionary<string, AiAgentRegistration>(StringComparer.Ordinal);

        for (var index = 0; index < entries.Count; index++)
        {
            var path = $"Agents[{index}]";
            var entry = entries[index];

            var agentId = Required(entry.AgentId, path, "AgentId");

            var registration = new AiAgentRegistration
            {
                AgentId = agentId,
                DisplayName = Required(entry.DisplayName, path, "DisplayName"),
                Purpose = Required(entry.Purpose, path, "Purpose"),
                AllowedCapabilities = ParseCapabilities(entry.AllowedCapabilities, path, "AllowedCapabilities"),
                AllowedToolIds = ParseIdentifiers(entry.AllowedToolIds, path, "AllowedToolIds"),
                MaxClassification = ParseEnum(
                    entry.MaxClassification, DataClassification.Public, path, "classification"),
                PromptId = Trimmed(entry.PromptId),
                RequiredReasoning = ParseEnum(
                    entry.RequiredReasoning, AiReasoningClass.None, path, "reasoning class"),
                MaxSideEffect = ParseEnum(
                    entry.MaxSideEffect, ToolSideEffectClass.None, path, "side-effect class"),
                GovernanceClass = ParseEnum(
                    entry.GovernanceClass, AiDependencyClass.AiOptional, path, "dependency class"),
                Enabled = entry.Enabled,
                Approval = ParseEnum(entry.Approval, AiGovernanceApprovalStatus.Unregistered, path, "approval status"),
                ApprovedBy = Trimmed(entry.ApprovedBy),
                GovernanceRationale = Required(entry.GovernanceRationale, path, "GovernanceRationale"),
            };

            if (!agents.TryAdd(agentId, registration))
            {
                throw new InvalidOperationException(
                    $"{path}: agent '{agentId}' is declared more than once. Two entries for one identity "
                    + "would make every decision that names it ambiguous.");
            }
        }

        return agents;
    }

    /// <summary>
    /// Parses the tool declarations.
    /// </summary>
    /// <remarks>
    /// <b><c>SideEffect</c> is required and has no absent default.</b> Every other governance field on
    /// a tool has a fail-closed default, but a side effect does not: the engine's own register treats
    /// an unclassified tool as more severe than any known class
    /// (<see cref="AiGovernanceRules.ToolUnknown"/>), because the failure mode of a tool register is a
    /// newly registered tool being permitted by omission. Defaulting an unstated effect to
    /// <see cref="ToolSideEffectClass.None"/> here would reintroduce exactly that omission one layer
    /// up — the entry would look classified and would be classified as harmless. So an entry that does
    /// not state its effect is refused at load, and the operator states it.
    /// </remarks>
    private static Dictionary<string, AiToolRegistration> BuildTools(List<AiToolConfigurationEntry> entries)
    {
        var tools = new Dictionary<string, AiToolRegistration>(StringComparer.Ordinal);

        for (var index = 0; index < entries.Count; index++)
        {
            var path = $"Tools[{index}]";
            var entry = entries[index];

            var toolId = Required(entry.ToolId, path, "ToolId");

            if (string.IsNullOrWhiteSpace(entry.SideEffect))
            {
                throw new InvalidOperationException(
                    $"{path}: tool '{toolId}' states no SideEffect. An unstated effect is not a "
                    + "classification: the governance engine refuses a tool it cannot classify, and "
                    + $"defaulting this to '{nameof(ToolSideEffectClass.None)}' here would make an "
                    + "unassessed tool look like a harmless one. State the effect explicitly.");
            }

            // The rule identifier the tool projects into the governance policy table is derived from
            // the tool id, and the policy validates every rule identifier against the shared
            // <domain>.<object> format. Checking it here turns "one tool in the estate has an
            // identifier the policy will reject at composition" into a message that names the entry.
            var ruleId = $"tool.{toolId}";

            if (!CapabilityId.IsValid(ruleId))
            {
                throw new InvalidOperationException(
                    $"{path}: tool id '{toolId}' is not usable as a governance rule identifier. The "
                    + $"register projects tool rules as 'tool.<toolId>' ('{ruleId}' here) and that must "
                    + "be a valid lowercase dot-separated identifier, because an audit record resolves "
                    + "the rule that refused it by that name.");
            }

            var registration = new AiToolRegistration
            {
                ToolId = toolId,
                DisplayName = Required(entry.DisplayName, path, "DisplayName"),
                Purpose = Required(entry.Purpose, path, "Purpose"),
                SideEffect = ParseEnum(entry.SideEffect, ToolSideEffectClass.None, path, "side-effect class"),
                RequiresHumanApproval = entry.RequiresHumanApproval,
                MaxClassification = ParseEnum(
                    entry.MaxClassification, DataClassification.Public, path, "classification"),
                AllowedCallerPermissions = ParseIdentifiers(
                    entry.AllowedCallerPermissions, path, "AllowedCallerPermissions"),
                DataScope = Trimmed(entry.DataScope),
                Enabled = entry.Enabled,
                GovernanceState = ParseEnum(
                    entry.GovernanceState, AiGovernanceApprovalStatus.Unregistered, path, "governance state"),
                Rationale = Required(entry.Rationale, path, "Rationale"),
            };

            if (!tools.TryAdd(toolId, registration))
            {
                throw new InvalidOperationException(
                    $"{path}: tool '{toolId}' is declared more than once. Two entries for one identity "
                    + "would make the effect the engine classifies depend on which was read first.");
            }
        }

        return tools;
    }

    /// <summary>Parses the prompt and instruction-set declarations.</summary>
    private static Dictionary<string, AiPromptRegistration> BuildPrompts(
        List<AiPromptConfigurationEntry> entries)
    {
        var prompts = new Dictionary<string, AiPromptRegistration>(StringComparer.Ordinal);

        for (var index = 0; index < entries.Count; index++)
        {
            var path = $"Prompts[{index}]";
            var entry = entries[index];

            var promptId = Required(entry.PromptId, path, "PromptId");

            // A blank system frame is refused rather than stored. It would be an instruction set that
            // steers nothing while appearing in an audit record as the instruction set that was
            // applied — a record that says a prompt was used and cannot say what it said.
            var systemFrame = Required(entry.SystemFrame, path, "SystemFrame");

            var registration = new AiPromptRegistration
            {
                PromptId = promptId,
                Version = Required(entry.Version, path, "Version"),
                Owner = Required(entry.Owner, path, "Owner"),
                Purpose = Required(entry.Purpose, path, "Purpose"),
                SystemFrame = systemFrame,
                Enabled = entry.Enabled,
                Approval = ParseEnum(entry.Approval, AiGovernanceApprovalStatus.Unregistered, path, "approval status"),
                Rationale = Required(entry.Rationale, path, "Rationale"),
            };

            if (!prompts.TryAdd(promptId, registration))
            {
                throw new InvalidOperationException(
                    $"{path}: prompt '{promptId}' is declared more than once. Two instruction sets under "
                    + "one identifier would make the version an execution was approved at ambiguous.");
            }
        }

        return prompts;
    }

    // --- Small parsers ------------------------------------------------------------------------------

    private static string? Trimmed(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    /// <summary>
    /// Parses a list of opaque identifiers, refusing blanks and duplicates.
    /// </summary>
    /// <remarks>
    /// Duplicates are refused rather than de-duplicated. A list that names the same tool twice is a
    /// list somebody edited by hand and did not read back, and silently collapsing it would hide the
    /// edit. Blank entries are refused for the same reason: an empty string in an allow-list is an
    /// entry that permits nothing and looks like it permits something.
    /// </remarks>
    private static IReadOnlyList<string> ParseIdentifiers(List<string> values, string path, string what)
    {
        if (values.Count == 0)
        {
            return [];
        }

        var parsed = new List<string>(values.Count);
        var seen = new HashSet<string>(StringComparer.Ordinal);

        for (var index = 0; index < values.Count; index++)
        {
            var value = values[index];

            if (string.IsNullOrWhiteSpace(value))
            {
                throw new InvalidOperationException($"{path}: {what}[{index}] is blank.");
            }

            var trimmed = value.Trim();

            if (!seen.Add(trimmed))
            {
                throw new InvalidOperationException($"{path}: {what}[{index}] '{trimmed}' is declared twice.");
            }

            parsed.Add(trimmed);
        }

        return parsed;
    }

    private static string Required(string? value, string path, string what)
        => string.IsNullOrWhiteSpace(value)
            ? throw new InvalidOperationException($"{path}: {what} is required and is missing or blank.")
            : value.Trim();

    private static TEnum ParseEnum<TEnum>(string? value, TEnum fallback, string path, string what)
        where TEnum : struct, Enum
        => ConfigurationEnum.Parse(value, fallback, path, what);

    /// <summary>
    /// Parses the declared processing tiers.
    /// </summary>
    /// <remarks>
    /// Absent means <see cref="AiProcessingTier.Standard"/> — the narrow claim. An operator who
    /// configures a tier has asserted something about the model; an operator who configures nothing
    /// has not, and reading silence as "supports everything" would let an unconfigured entry accept
    /// a batch request it never claimed to serve.
    /// </remarks>
    private static IReadOnlyList<AiProcessingTier> ParseTiers(List<string> values, string path)
    {
        if (values.Count == 0)
        {
            return [AiProcessingTier.Standard];
        }

        var parsed = new List<AiProcessingTier>(values.Count);

        for (var index = 0; index < values.Count; index++)
        {
            var tier = ParseEnum(values[index], AiProcessingTier.Standard, path, $"processing tier");

            if (parsed.Contains(tier))
            {
                throw new InvalidOperationException(
                    $"{path}: processing tier '{tier}' is declared more than once. A duplicate is not a " +
                    "stronger claim, and accepting it would make the declared list disagree with its own " +
                    "length.");
            }

            parsed.Add(tier);
        }

        return parsed;
    }

    /// <summary>
    /// Parses an ISO date, refusing anything that is not one.
    /// </summary>
    /// <remarks>
    /// A price effective date that silently failed to parse would leave the estate pricing from a
    /// rate whose validity it believes it stated but did not. Failing the load is the only reading
    /// that does not quietly discard an operator's assertion.
    /// </remarks>
    private static DateOnly? ParseDate(string? value, string path, string what)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        if (!DateOnly.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed))
        {
            throw new InvalidOperationException(
                $"{path}: {what} '{value}' is not a valid ISO date (yyyy-MM-dd).");
        }

        return parsed;
    }

    private static IReadOnlyList<CapabilityId> ParseCapabilities(
        List<string> values, string path, string what = "Capabilities")
    {
        if (values.Count == 0)
        {
            return [];
        }

        var parsed = new List<CapabilityId>(values.Count);

        for (var index = 0; index < values.Count; index++)
        {
            var value = values[index];

            if (!CapabilityId.TryParse(value, out var capability, out var reason) || capability is null)
            {
                throw new InvalidOperationException(
                    $"{path}: {what}[{index}] '{value}' is not a valid capability identifier. {reason}");
            }

            parsed.Add(capability);
        }

        return parsed;
    }

    private static IReadOnlyList<AiModelModality> ParseModalities(
        List<string> values, string path, string what)
    {
        // Absent means text, because a request that says nothing is text. Declaring an empty list
        // explicitly is not distinguishable from omitting the key, and treating it as "no modalities"
        // would make an unstated modality the strictest possible value and refuse everything.
        if (values.Count == 0)
        {
            return [AiModelModality.Text];
        }

        var parsed = new List<AiModelModality>(values.Count);

        for (var index = 0; index < values.Count; index++)
        {
            parsed.Add(ParseEnum<AiModelModality>(values[index], AiModelModality.Text, path, $"{what} modality"));
        }

        return parsed;
    }
}
