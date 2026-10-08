namespace Nexus.Intelligence.Contracts;

/// <summary>Which Head, Product or system is asking.</summary>
/// <remarks>
/// A fixed, small vocabulary rather than a free string. The audit record answers "who asked" for every
/// AI execution in the estate, and a free string would make that answer unaggregatable — "Forge",
/// "forge" and "Forge DevBridge" would be three requesters. Adding a Head is a deliberate act.
/// </remarks>
public enum CallingHead
{
    /// <summary>Not attributable to a Head — a diagnostic or bootstrap caller. Requires a written reason.</summary>
    Unspecified = 0,

    /// <summary>The Nexus AI Head itself, for internal sub-execution.</summary>
    Ai = 1,

    /// <summary>Platform. Platform governance is AI-free by principle; this is for advisory paths only.</summary>
    Platform = 2,

    /// <summary>Forge, the development control plane.</summary>
    Forge = 3,

    /// <summary>A Product (Nexus Developer, Nexus Experience/Chat, Business OS, …).</summary>
    Product = 4,

    /// <summary>A CI/CD pipeline or scheduled job.</summary>
    Automation = 5,
}

/// <summary>What a caller is permitted to cause, as distinct from what it is permitted to see.</summary>
/// <remarks>
/// <para>
/// Kept separate from the data scope on purpose. A caller holding <c>financial.read</c> has a data
/// scope; it does not thereby have a tool scope. Collapsing the two is how a read permission silently
/// becomes a write capability.
/// </para>
/// </remarks>
public sealed record AiPermissionScope
{
    /// <summary>Opaque permission keys the caller already holds, as issued by Platform identity.</summary>
    public IReadOnlyList<string> Permissions { get; init; } = [];

    /// <summary>True when the caller may cause a side-effecting action at all. Defaults to false.</summary>
    public bool MayCauseSideEffects { get; init; }

    /// <summary>True when a human must approve every side-effecting action. Defaults to true.</summary>
    /// <remarks>
    /// Defaults to the safe value in both directions: no side effects, and approval required if one is
    /// ever permitted. A caller that wants autonomy must say so explicitly and be authorised for it.
    /// </remarks>
    public bool RequiresHumanApprovalForSideEffects { get; init; } = true;

    public static AiPermissionScope None { get; } = new();
}

/// <summary>
/// The identity of an AI requester: enough to audit <em>who asked</em>, <em>for what</em>, and
/// <em>within which scope</em> — and deliberately not enough to reach a provider.
/// </summary>
/// <remarks>
/// <para>
/// <b>This type carries no credential, no endpoint and no provider handle, by construction.</b> The
/// W7A directive's rule is that callers must not acquire provider credentials directly; the way that
/// is enforced is that there is no field here capable of holding one, so a caller cannot pass one even
/// if it has one. Credentials are resolved by the AI Head, below this boundary, from
/// <c>Nexus.Platform.Contracts.Secrets.ISecretResolver</c>.
/// </para>
/// <para>
/// <see cref="ProductId"/>, <see cref="TenantId"/> and <see cref="WorkspaceId"/> are opaque strings.
/// The AI Head stores and compares them and never parses them — the same rule that already governs
/// <see cref="ScopeRef"/>. This type must never gain a member that means "what a Workspace is".
/// </para>
/// </remarks>
public sealed record AiRequesterIdentity
{
    /// <summary>Which Head or Product is asking.</summary>
    public required CallingHead Head { get; init; }

    /// <summary>Opaque product identifier, when the caller is a Product. Never parsed.</summary>
    public string? ProductId { get; init; }

    /// <summary>Opaque tenant identifier. Never parsed.</summary>
    public string? TenantId { get; init; }

    /// <summary>Opaque workspace identifier, where the product has one. Never parsed.</summary>
    public string? WorkspaceId { get; init; }

    /// <summary>
    /// The end user or service principal on whose behalf the call is made. Required: an AI execution
    /// that cannot name its principal cannot be attributed, and attribution is the audit record's
    /// first purpose.
    /// </summary>
    public required string PrincipalId { get; init; }

    /// <summary>True when <see cref="PrincipalId"/> is a service principal rather than a human.</summary>
    public bool IsServicePrincipal { get; init; }

    /// <summary>What the caller may cause.</summary>
    public AiPermissionScope PermissionScope { get; init; } = AiPermissionScope.None;

    /// <summary>
    /// The data scopes the caller asserts the context was drawn from, e.g. <c>tenant:acme</c>.
    /// </summary>
    /// <remarks>
    /// Declared, not trusted. The exposure policy compares this against the actual
    /// <see cref="DataClassification"/> of the context and refuses a mismatch — a caller that
    /// under-declares its scope does not thereby lower the classification.
    /// </remarks>
    public IReadOnlyList<string> DataScopes { get; init; } = [];
}
