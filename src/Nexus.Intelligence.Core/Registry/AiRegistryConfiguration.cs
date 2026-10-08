namespace Nexus.Intelligence.Core.Registry;

/// <summary>
/// The configuration shape of the model and provider registry.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is where the estate's models and providers are declared, and it is the only such place.</b>
/// The directive's "do not hardcode the permanent model list into router code" is answered here: the
/// router holds no identifier, and the list it routes over arrived through this type from
/// configuration. Adding a model is a configuration change; removing one is a configuration change;
/// neither is a code change and neither needs a release.
/// </para>
/// <para>
/// <b>Mutable settable properties, on purpose, and this is the one place in W7C where that is true.</b>
/// The configuration binder needs them. Everything downstream of the parse is the immutable
/// <see cref="Nexus.Intelligence.Contracts.AiModelRegistration"/> and
/// <see cref="Nexus.Intelligence.Contracts.AiProviderRegistration"/>, so the mutability is confined to
/// the type that exists for exactly as long as it takes to read the file.
/// </para>
/// <para>
/// Every property is nullable or defaulted, and the parse decides what an absent value means. The
/// direction is always the same: <b>absent means refused</b> — not enabled, not approved, not
/// routable — so a half-written entry produces a model that cannot be used rather than one that can.
/// </para>
/// </remarks>
public sealed class AiRegistryConfiguration
{
    /// <summary>The configuration section this type binds from.</summary>
    public const string SectionName = "Ai:Registry";

    /// <summary>
    /// Where these values came from, in the operator's own words.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Provenance is what makes a bootstrap default honest.</b> A registry entry is a claim about
    /// the world — this model exists, it costs this much, it is approved — and a claim with no stated
    /// source is a claim nobody can check or date. This field is where the estate records that a set
    /// of entries was transcribed from a vendor's published price list on a given date, or seeded from
    /// a predecessor system, rather than being discovered by reading the file and guessing.
    /// </para>
    /// <para>
    /// It is free text and nothing parses it. Its value is that the question "why is this model
    /// registered?" has an answer inside the artefact that answers it.
    /// </para>
    /// </remarks>
    public string? Provenance { get; set; }

    /// <summary>How the router chooses between permitted routes.</summary>
    public AiRoutingConfigurationEntry Routing { get; set; } = new();

    /// <summary>The providers the estate may send content to.</summary>
    public List<AiProviderConfigurationEntry> Providers { get; set; } = [];

    /// <summary>The models the estate may route to.</summary>
    public List<AiModelConfigurationEntry> Models { get; set; } = [];

    /// <summary>
    /// An operator's declared health for providers and models.
    /// </summary>
    /// <remarks>
    /// <b>A declared snapshot, and the seam a real health source replaces.</b> W7C needs health as an
    /// input and has no probe; the honest options are to declare it in configuration or to have none,
    /// and having none means nothing routes. The values here are what an operator is asserting right
    /// now, and the operations lane replaces this source with observed evidence without the router
    /// changing at all — which is the point of health arriving through a port.
    /// </remarks>
    public List<AiHealthConfigurationEntry> Health { get; set; } = [];

    /// <summary>
    /// The agents the estate may dispatch, in the same section as the models they act through.
    /// </summary>
    /// <remarks>
    /// W7D TASK 2. Before this collection existed an agent was a C# class with an identifier, a name
    /// and a description, registered in the composition root, and the registry that indexed them
    /// resolved identifiers through a <c>switch</c> compiled into the assembly. An agent could not be
    /// given a prompt, a tool grant, a classification ceiling or an off switch, because no such field
    /// existed anywhere. They are declared here now, which is what makes
    /// <see cref="Nexus.Intelligence.Contracts.IAiAgentRegistry"/> a registry rather than a
    /// dictionary of singletons.
    /// </remarks>
    public List<AiAgentConfigurationEntry> Agents { get; set; } = [];

    /// <summary>
    /// The tools an AI execution may reach, with their effect classifications.
    /// </summary>
    /// <remarks>
    /// W7D TASK 3. The Platform tool catalogue remains the authority for which implementations exist;
    /// this is the authority for which of them may be called and how far they reach. Nothing projected
    /// into these entries before W7D, which made every tool identifier
    /// <see cref="Nexus.Intelligence.Contracts.AiGovernanceRules.ToolUnknown"/> — refused, correctly,
    /// but from a table no operator could fill.
    /// </remarks>
    public List<AiToolConfigurationEntry> Tools { get; set; } = [];

    /// <summary>
    /// The prompt and instruction sets the estate may apply, with their text and their versions.
    /// </summary>
    /// <remarks>
    /// W7D TASK 6. Instruction text was compiled into C# string literals — one of them a JSON-shape
    /// directive inside the planner, another assembled from five fragments inside the prompt step.
    /// Neither could be versioned, reviewed, or changed by the person who owned its behaviour. They
    /// are declared here now.
    /// </remarks>
    public List<AiPromptConfigurationEntry> Prompts { get; set; } = [];
}

/// <summary>How the router chooses between permitted routes, as configuration.</summary>
public sealed class AiRoutingConfigurationEntry
{
    /// <summary>
    /// The ranking objective, by name. Absent means
    /// <see cref="Nexus.Intelligence.Contracts.AiRoutingObjective.Balanced"/>.
    /// </summary>
    public string? Objective { get; set; }

    /// <summary>
    /// How many routes beyond the primary a failover may walk. Negative is refused at load.
    /// </summary>
    /// <remarks>
    /// A bound on how many providers one caller request may touch. It is configuration because the
    /// right value is an operational judgement — one fallback is right for an estate whose providers
    /// rarely correlate, and zero is right for an estate that would rather fail fast than degrade
    /// slowly — and a number in code would be an opinion nobody could revise.
    /// </remarks>
    public int FallbackDepth { get; set; } = 1;
}

/// <summary>One provider, as configuration declares it.</summary>
public sealed class AiProviderConfigurationEntry
{
    /// <summary>The stable provider identifier. Required.</summary>
    public string? ProviderId { get; set; }

    /// <summary>A human-readable name. Required.</summary>
    public string? DisplayName { get; set; }

    /// <summary>The assembly-qualified type name of the serving adapter. Required.</summary>
    public string? AdapterIdentity { get; set; }

    /// <summary>Capability identifiers this provider can serve at all.</summary>
    public List<string> Capabilities { get; set; } = [];

    /// <summary>Whether the provider is switched on.</summary>
    public bool Enabled { get; set; }

    /// <summary>
    /// The <em>name</em> of the environment variable holding the credential — never its value.
    /// </summary>
    /// <remarks>
    /// Validated against <c>AiProviderRegistration.IsWellFormedSecretReference</c> at load, so a value
    /// pasted here where a name belongs fails the parse rather than being stored. See that member's
    /// remarks for what the shape check does and does not guarantee.
    /// </remarks>
    public string? SecretReference { get; set; }

    /// <summary>Whether content may reach this provider over the network at all.</summary>
    public bool PermitsRemoteEgress { get; set; }

    /// <summary>Trust tier by name. Absent means untrusted.</summary>
    public string? Trust { get; set; }

    /// <summary>Ordinal preference. Higher is preferred.</summary>
    public int Priority { get; set; }

    /// <summary>Cardinal multiplier on this provider's contribution to a score. Defaults to 1.</summary>
    public double? Weight { get; set; }

    /// <summary>Approval status by name. Absent means unregistered, which refuses.</summary>
    public string? Approval { get; set; }

    /// <summary>Classification ceiling by name. Absent means public, the narrowest.</summary>
    public string? MaxClassification { get; set; }

    /// <summary>Who approved it.</summary>
    public string? ApprovedBy { get; set; }

    /// <summary>Why it is in the state it is in. Required.</summary>
    public string? GovernanceRationale { get; set; }
}

/// <summary>One model, as configuration declares it.</summary>
public sealed class AiModelConfigurationEntry
{
    /// <summary>The model identifier, vendor-prefixed. Required.</summary>
    public string? ModelId { get; set; }

    /// <summary>The provider that serves it. Required.</summary>
    public string? ProviderId { get; set; }

    /// <summary>A human-readable name. Required.</summary>
    public string? DisplayName { get; set; }

    /// <summary>Capability identifiers this model serves.</summary>
    public List<string> Capabilities { get; set; } = [];

    /// <summary>Accepted input tokens, where the vendor states it.</summary>
    public int? MaxContextTokens { get; set; }

    /// <summary>Emitted output tokens, where the vendor states it.</summary>
    public int? MaxOutputTokens { get; set; }

    /// <summary>Input modalities by name. Absent means text.</summary>
    public List<string> InputModalities { get; set; } = [];

    /// <summary>Output modalities by name. Absent means text.</summary>
    public List<string> OutputModalities { get; set; } = [];

    /// <summary>Reasoning class by name. Absent means none.</summary>
    public string? Reasoning { get; set; }

    /// <summary>Relative speed by name. Absent means unknown.</summary>
    public string? RelativeSpeed { get; set; }

    /// <summary>Lifecycle availability by name. Absent means unknown, which is not routable.</summary>
    public string? Availability { get; set; }

    /// <summary>Whether the model is switched on.</summary>
    public bool Enabled { get; set; }

    /// <summary>Where the rates below were transcribed from.</summary>
    public string? CostMetadataReference { get; set; }

    /// <summary>Cost per thousand input tokens.</summary>
    public decimal? InputCostPer1kTokens { get; set; }

    /// <summary>Cost per thousand output tokens.</summary>
    public decimal? OutputCostPer1kTokens { get; set; }

    /// <summary>ISO 4217 code for both rates.</summary>
    public string? CostCurrency { get; set; }

    /// <summary>
    /// Where the stated rates stand, by name: Current, NeedsReview, Expired or ManualOverride.
    /// </summary>
    /// <remarks>
    /// Absent means <c>Current</c>. An expired rate is refused rather than used, so this is the field
    /// that lets an operator stop the estate pricing from a rate they know is wrong without deleting
    /// it — deleting it would lose the record that it was once believed.
    /// </remarks>
    public string? PriceStatus { get; set; }

    /// <summary>The date the stated rates took effect, in ISO form.</summary>
    public string? PriceEffectiveFrom { get; set; }

    /// <summary>The date the stated rates stopped applying, in ISO form.</summary>
    public string? PriceEffectiveTo { get; set; }

    /// <summary>
    /// Processing tiers this model supports, by name. Absent means standard processing only.
    /// </summary>
    /// <remarks>
    /// W7E TASK 6. Declared, never inferred — the tier gate reads this list and nothing else, so a
    /// model whose configuration says nothing about tiers supports exactly the interactive case.
    /// </remarks>
    public List<string> ProcessingTiers { get; set; } = [];

    /// <summary>Approval status by name. Absent means unregistered, which refuses.</summary>
    public string? Approval { get; set; }

    /// <summary>Classification ceiling by name. Absent means public, the narrowest.</summary>
    public string? MaxClassification { get; set; }

    /// <summary>Who approved it.</summary>
    public string? ApprovedBy { get; set; }

    /// <summary>Why it is in the state it is in. Required.</summary>
    public string? GovernanceRationale { get; set; }
}

/// <summary>One agent, as configuration declares it.</summary>
public sealed class AiAgentConfigurationEntry
{
    /// <summary>The agent identifier. Required.</summary>
    public string? AgentId { get; set; }

    /// <summary>A human-readable name. Required.</summary>
    public string? DisplayName { get; set; }

    /// <summary>What the agent is for. Required.</summary>
    public string? Purpose { get; set; }

    /// <summary>Capability identifiers this agent may serve.</summary>
    public List<string> AllowedCapabilities { get; set; } = [];

    /// <summary>Tool identifiers this agent may use.</summary>
    public List<string> AllowedToolIds { get; set; } = [];

    /// <summary>Classification ceiling by name. Absent means public, the narrowest.</summary>
    public string? MaxClassification { get; set; }

    /// <summary>The prompt or instruction set this agent operates under.</summary>
    public string? PromptId { get; set; }

    /// <summary>Reasoning class by name. Absent means no requirement.</summary>
    public string? RequiredReasoning { get; set; }

    /// <summary>Side-effect ceiling by name. Absent means none, the narrowest.</summary>
    public string? MaxSideEffect { get; set; }

    /// <summary>AI dependency class by name. Absent means optional.</summary>
    public string? GovernanceClass { get; set; }

    /// <summary>Whether the agent is switched on.</summary>
    public bool Enabled { get; set; }

    /// <summary>Approval status by name. Absent means unregistered, which refuses.</summary>
    public string? Approval { get; set; }

    /// <summary>Who approved it.</summary>
    public string? ApprovedBy { get; set; }

    /// <summary>Why it is in the state it is in. Required.</summary>
    public string? GovernanceRationale { get; set; }
}

/// <summary>One tool, as configuration declares it.</summary>
public sealed class AiToolConfigurationEntry
{
    /// <summary>The tool identifier. Required.</summary>
    public string? ToolId { get; set; }

    /// <summary>A human-readable name. Required.</summary>
    public string? DisplayName { get; set; }

    /// <summary>What the tool is for. Required.</summary>
    public string? Purpose { get; set; }

    /// <summary>Side-effect class by name. Required — an unstated effect is not a classification.</summary>
    public string? SideEffect { get; set; }

    /// <summary>True when every call needs a human's approval, whatever the profile says.</summary>
    public bool RequiresHumanApproval { get; set; }

    /// <summary>Classification ceiling by name. Absent means public, the narrowest.</summary>
    public string? MaxClassification { get; set; }

    /// <summary>Caller permission keys that may invoke this tool.</summary>
    public List<string> AllowedCallerPermissions { get; set; } = [];

    /// <summary>The data scope the tool reaches. Null means undeclared.</summary>
    public string? DataScope { get; set; }

    /// <summary>Whether the tool is switched on.</summary>
    public bool Enabled { get; set; }

    /// <summary>Governance state by name. Absent means unregistered, which refuses.</summary>
    public string? GovernanceState { get; set; }

    /// <summary>Why it is classified as it is. Required.</summary>
    public string? Rationale { get; set; }
}

/// <summary>One prompt or instruction set, as configuration declares it.</summary>
public sealed class AiPromptConfigurationEntry
{
    /// <summary>The prompt identifier. Required.</summary>
    public string? PromptId { get; set; }

    /// <summary>The version of this instruction set. Required.</summary>
    public string? Version { get; set; }

    /// <summary>The accountable owner. Required.</summary>
    public string? Owner { get; set; }

    /// <summary>What the instruction set is for. Required.</summary>
    public string? Purpose { get; set; }

    /// <summary>The instruction text applied as the system frame. Required.</summary>
    public string? SystemFrame { get; set; }

    /// <summary>Whether the instruction set is switched on.</summary>
    public bool Enabled { get; set; }

    /// <summary>Approval status by name. Absent means unregistered, which refuses.</summary>
    public string? Approval { get; set; }

    /// <summary>Why it is in the state it is in. Required.</summary>
    public string? Rationale { get; set; }
}

/// <summary>One declared health value, for a provider or for one model on it.</summary>
public sealed class AiHealthConfigurationEntry
{
    /// <summary>The provider this entry is about. Required.</summary>
    public string? ProviderId { get; set; }

    /// <summary>
    /// The model this entry is about, or null for the provider as a whole.
    /// </summary>
    /// <remarks>
    /// Both are needed because the two health questions are independent: a provider can be throttling
    /// as a whole while one model is withdrawn, and collapsing them into one value would force an
    /// operator to choose which of the two facts to lose.
    /// </remarks>
    public string? ModelId { get; set; }

    /// <summary>The health state by name. Absent means unknown, which is not routable.</summary>
    public string? State { get; set; }
}
