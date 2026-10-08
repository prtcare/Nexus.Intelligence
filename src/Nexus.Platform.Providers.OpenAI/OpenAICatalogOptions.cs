namespace Nexus.Platform.Providers.OpenAI;

/// <summary>
/// The models this provider adapter will report to the estate's catalog.
/// </summary>
/// <remarks>
/// <para>
/// <b>Configuration, not code, and W7C TASK 7 is why.</b> These entries were a <c>static readonly</c>
/// array of <c>ModelDescriptor</c> literals compiled into <see cref="OpenAIModelCatalogSource"/>. The
/// array is what made <c>openai:gpt-4.1</c> a permanent code-level model fact: adding a model, retiring
/// one, or repricing one was a source change and a release, and the file's own list was the only place
/// the estate could learn which models exist. Moving it here makes the list a deployment's statement
/// about itself.
/// </para>
/// <para>
/// <b>Bound relative to the provider section, not the configuration root.</b> The composition root
/// passes <c>Platform:Providers</c>, so <see cref="SectionName"/> resolves to
/// <c>Platform:Providers:OpenAI:Catalog</c>. That is the same relative convention
/// <see cref="OpenAIOptions"/> uses, and it keeps the provider's keys under the provider's own path.
/// </para>
/// <para>
/// <b>An empty catalog is a valid state.</b> An estate that configures no models gets a source that
/// reports none, and role resolution then fails closed rather than falling back to a model named in
/// code. That is the same deliberate refusal <c>ConfiguredAiRegistry.Empty</c> ships with.
/// </para>
/// </remarks>
public sealed class OpenAICatalogOptions
{
    /// <summary>Relative to the provider configuration section. See the remarks on this type.</summary>
    public const string SectionName = "OpenAI:Catalog";

    /// <summary>
    /// Where this list came from, and when it was last reconciled with the provider.
    /// </summary>
    /// <remarks>
    /// The member exists so a list that has drifted is discoverable. A model inventory with no
    /// provenance cannot be audited: a reviewer confronted with an entry that no longer exists upstream,
    /// or a price that no longer matches, has no way to tell whether it was wrong when written or
    /// correct when written and stale now.
    /// </remarks>
    public string? Provenance { get; set; }

    /// <summary>The models. See <see cref="OpenAICatalogModelEntry"/> for what each entry must state.</summary>
    public List<OpenAICatalogModelEntry> Models { get; set; } = [];
}

/// <summary>
/// One model as the operator declares it.
/// </summary>
/// <remarks>
/// Every member is nullable or defaulted because this is the shape the binder fills; the nullability is
/// not a statement that the value may be omitted. <see cref="OpenAIModelCatalogSource"/> validates on
/// build and refuses a malformed entry at composition.
/// </remarks>
public sealed class OpenAICatalogModelEntry
{
    /// <summary>The estate's identifier for the model, e.g. <c>openai:gpt-4.1</c>.</summary>
    public string? ModelId { get; set; }

    /// <summary>The vendor that serves it, e.g. <c>openai</c>.</summary>
    public string? Vendor { get; set; }

    /// <summary>
    /// The capabilities the model declares, as <c>ModelCapabilities</c> member names.
    /// </summary>
    /// <remarks>
    /// Flag members, comma-separated if given as one string. Each name is validated individually,
    /// because a flags enum admits combinations that <c>Enum.IsDefined</c> does not recognise — which is
    /// exactly how a typo like <c>Chatt</c> would otherwise be stored as a number nobody queries.
    /// </remarks>
    public List<string> Capabilities { get; set; } = [];

    /// <summary>The context window in tokens.</summary>
    public int ContextWindow { get; set; }

    /// <summary>Cost per thousand input tokens, in <c>CostCurrency</c> of the estate's choosing.</summary>
    public decimal CostPer1kIn { get; set; }

    /// <summary>Cost per thousand output tokens.</summary>
    public decimal CostPer1kOut { get; set; }

    /// <summary>The latency class, as a <c>LatencyClass</c> member name.</summary>
    public string? Latency { get; set; }
}
