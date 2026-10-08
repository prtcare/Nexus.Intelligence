namespace Nexus.Intelligence.Contracts;

/// <summary>
/// One tool, as the AI Head's registry states it: what it does, how far it reaches, who may call it,
/// and whether it is on offer at all.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why the AI Head keeps its own tool registry.</b> The tool <em>implementations</em> are
/// Platform's: <c>IToolCatalog</c> and <c>IToolGateway</c> are pinned Platform contracts, and
/// <c>ToolDescriptor</c> carries an identity, a display name, a description and a Platform
/// <c>SideEffectClass</c>. None of that is an AI governance fact. A Platform side-effect class says
/// what a tool does to Platform state; it says nothing about whether an AI execution may reach it,
/// on what data, or under whose authority. That question is this register's, and it is answered here
/// rather than by widening the Platform contract — the AI boundary does not get to redefine what a
/// Platform tool is.
/// </para>
/// <para>
/// <b>The register is what makes <see cref="AiGovernanceRules.ToolUnknown"/> reachable.</b> The
/// engine refuses any tool identifier it cannot classify, and it classifies tools from
/// <see cref="AiGovernancePolicy.Tools"/>. Before W7D that list was empty on every estate and
/// nothing projected into it, so every tool call was unknown and refused — correct, but only
/// accidentally: the refusal came from a table nobody could populate. This record is how an operator
/// populates it.
/// </para>
/// <para>
/// <b>The defaults all refuse.</b> <see cref="Enabled"/> is false, <see cref="GovernanceState"/> is
/// <see cref="AiGovernanceApprovalStatus.Unregistered"/> and <see cref="SideEffect"/> is
/// <see cref="ToolSideEffectClass.None"/>. A side effect of <c>None</c> is not a permission to run
/// the tool: <see cref="AiGovernanceRules.ToolNotPermitted"/> still refuses any tool absent from the
/// execution's permission profile, and <see cref="Enabled"/> still has to be set.
/// </para>
/// </remarks>
public sealed record AiToolRegistration
{
    /// <summary>The tool identifier, as the Platform tool catalogue states it. The governance key.</summary>
    public required string ToolId { get; init; }

    /// <summary>A human-readable name, for reports and for the system frame. Never used to decide anything.</summary>
    public required string DisplayName { get; init; }

    /// <summary>What this tool is for, in an operator's words. Required, so no tool arrives unexplained.</summary>
    public required string Purpose { get; init; }

    /// <summary>
    /// How severe this tool's effect is, in the AI boundary's own vocabulary.
    /// </summary>
    /// <remarks>
    /// <see cref="ToolSideEffectClass"/> and not Platform's <c>SideEffectClass</c>, because the two
    /// answer different questions — see the remarks on <see cref="ToolSideEffectClass"/>. The
    /// operator transcribes the Platform class into this one deliberately: a tool whose Platform
    /// class is <c>Write</c> and whose AI class nobody stated is a tool whose effect on the AI
    /// boundary is unknown, and the act of stating it is the review.
    /// </remarks>
    public required ToolSideEffectClass SideEffect { get; init; }

    /// <summary>
    /// True when a human must approve every call, whatever the execution's profile says.
    /// </summary>
    /// <remarks>
    /// A property of the tool rather than of the caller's grant. It exists so that a tool can be
    /// declared permanently human-gated — a deployment, a destructive migration — and no profile
    /// can widen past it: the engine refuses to execute and raises
    /// <see cref="AiGovernanceRules.ToolApprovalRequired"/> instead.
    /// </remarks>
    public bool RequiresHumanApproval { get; init; }

    /// <summary>The most sensitive classification this tool may be pointed at.</summary>
    public DataClassification MaxClassification { get; init; } = DataClassification.Public;

    /// <summary>
    /// The caller permission keys that may invoke this tool. Empty means nobody.
    /// </summary>
    /// <remarks>
    /// Scoped to <see cref="AiRequesterIdentity.PermissionScope"/>'s permission keys. Separate from
    /// <see cref="AllowedToolIds"/> on the agent for the reason the two registries are separate: an
    /// agent is granted a tool because the work needs it, and this list bounds who may be doing that
    /// work at all. A tool reachable by any caller that happens to hold the identifier is a tool
    /// whose authority is a naming convention.
    /// </remarks>
    public IReadOnlyList<string> AllowedCallerPermissions { get; init; } = [];

    /// <summary>
    /// The data scope this tool reads or writes, e.g. <c>tenant:acme</c>. Null means unscoped.
    /// </summary>
    /// <remarks>
    /// A declaration for review and audit, not a runtime check: the AI Head cannot verify that a
    /// tool implementation respected the scope it was declared with. It is recorded so that "which
    /// tools reach customer data" is answerable from the registry rather than by reading every
    /// implementation — which is the question a reviewer actually asks, and one an unstated scope
    /// makes unanswerable.
    /// </remarks>
    public string? DataScope { get; init; }

    /// <summary>Whether an operator has switched this tool on. Defaults to off.</summary>
    public bool Enabled { get; init; }

    /// <summary>Whether the tool has been assessed and approved for use.</summary>
    public AiGovernanceApprovalStatus GovernanceState { get; init; } = AiGovernanceApprovalStatus.Unregistered;

    /// <summary>Why the tool is classified as it is. Required, so no classification arrives unexplained.</summary>
    public required string Rationale { get; init; }

    /// <summary>True when the tool causes an effect the AI boundary treats as side-effecting.</summary>
    public bool CausesSideEffects => SideEffect >= ToolSideEffectClass.Write;
}

/// <summary>
/// The tools that exist, and what each of them is.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the AI Head's tool registry, and the only place a tool's governance facts live.</b>
/// The Platform tool catalogue remains the authority for which implementations exist; this register
/// is the authority for which of them an AI execution may reach, and under what terms. A tool present
/// in the Platform catalogue and absent here is <see cref="AiGovernanceRules.ToolUnknown"/> — a
/// refusal, and the direction that failure must go.
/// </para>
/// <para>
/// <see cref="GovernanceRules"/> is the projection onto <see cref="AiGovernancePolicy.Tools"/>.
/// It exists on this interface rather than being assembled by the composition root so that the
/// policy table and the registry cannot describe the same tool differently: one record, one
/// projection, one read surface.
/// </para>
/// </remarks>
public interface IAiToolRegistry
{
    /// <summary>Resolves a tool's registration, or returns <see langword="false"/> when nothing is registered under that identifier.</summary>
    bool TryGetTool(string? toolId, out AiToolRegistration? tool);

    /// <summary>
    /// The tool classifications the governance engine decides from.
    /// </summary>
    /// <remarks>
    /// Projected from the registrations. Empty on an estate with no tools registered, which makes
    /// every tool call <see cref="AiGovernanceRules.ToolUnknown"/> — the same fail-closed state the
    /// empty register has always produced, now reached from a table an operator can fill.
    /// </remarks>
    IReadOnlyList<AiGovernanceToolRule> GovernanceRules { get; }

    /// <summary>How many tools are registered. For composition assertions, not for enumeration.</summary>
    int Count { get; }
}

/// <summary>The registry that knows no tools: the state before any tool has been registered.</summary>
/// <remarks>
/// <b>This is the default, and it refuses everything.</b> Every tool identifier resolves to nothing,
/// every call is <see cref="AiGovernanceRules.ToolUnknown"/>, and no tool executes. That is the
/// correct state of an estate whose tool register has not been written, and it is the same
/// fail-closed posture the rest of the register family takes.
/// </remarks>
public sealed class EmptyAiToolRegistry : IAiToolRegistry
{
    /// <summary>The single instance. The registry is stateless.</summary>
    public static EmptyAiToolRegistry Instance { get; } = new();

    /// <inheritdoc />
    public bool TryGetTool(string? toolId, out AiToolRegistration? tool)
    {
        tool = null;
        return false;
    }

    /// <inheritdoc />
    public IReadOnlyList<AiGovernanceToolRule> GovernanceRules => [];

    /// <inheritdoc />
    public int Count => 0;
}
