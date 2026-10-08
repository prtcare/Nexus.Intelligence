namespace Nexus.Intelligence.Contracts;

/// <summary>
/// What a capability execution is allowed to <em>do</em> — as opposed to what it is allowed to read.
/// </summary>
/// <remarks>
/// <para>
/// This is the field that keeps an AI execution advisory. A capability that may read and reason is
/// the default; a capability that may write is an explicit grant, and every write-shaped grant
/// carries approval by default. V3 principle 7 says AI advice never overrides deterministic Platform
/// authority, and a tool profile that defaults to no side effects is how that principle survives
/// contact with an agent loop.
/// </para>
/// <para>
/// Tool <em>identifiers</em> appear here, so a caller states which tool kinds it is willing to expose.
/// It does not and cannot name a tool <em>implementation</em>: implementations are resolved by the AI
/// Head from the capability and the tool catalogue. A caller that could name an implementation could
/// reach one the AI Head did not intend to offer.
/// </para>
/// </remarks>
public sealed record ToolPermissionProfile
{
    /// <summary>Tool identifiers the caller permits. Empty means no tools at all.</summary>
    public IReadOnlyList<string> AllowedToolIds { get; init; } = [];

    /// <summary>
    /// The most severe side effect the caller permits. <see cref="ToolSideEffectClass.None"/> means
    /// the execution may not cause an effect of any kind.
    /// </summary>
    /// <remarks>
    /// A ceiling rather than a list, because the failure mode of a list is that a newly registered tool
    /// is silently permitted by omission. Anything above this ceiling is refused even if its identifier
    /// appears in <see cref="AllowedToolIds"/> — the two must both permit.
    /// </remarks>
    public ToolSideEffectClass MaxSideEffect { get; init; } = ToolSideEffectClass.None;

    /// <summary>True when a human must approve each side-effecting tool call. Defaults to true.</summary>
    public bool RequireApprovalForWrites { get; init; } = true;

    /// <summary>Maximum number of tool calls permitted in one execution. Bounds a runaway loop.</summary>
    public int MaxToolCalls { get; init; }

    /// <summary>No tools. The default, and the shape almost every capability should use.</summary>
    public static ToolPermissionProfile None { get; } = new();

    /// <summary>Read-only tools, no approval needed, because nothing is caused.</summary>
    public static ToolPermissionProfile ReadOnly(int maxToolCalls = 16) => new()
    {
        MaxSideEffect = ToolSideEffectClass.Read,
        RequireApprovalForWrites = true,
        MaxToolCalls = maxToolCalls,
    };
}

/// <summary>
/// How severe a tool's effect is. Owned here rather than reusing Platform's
/// <c>Nexus.Platform.Contracts.Tools.SideEffectClass</c> because the two answer different questions:
/// Platform's class describes what a tool does to Platform state, this one describes what the AI
/// boundary will permit.
/// </summary>
public enum ToolSideEffectClass
{
    /// <summary>No effect. Pure computation or reads that mutate nothing.</summary>
    None = 0,

    /// <summary>Reads data. No state is changed.</summary>
    Read = 1,

    /// <summary>Writes within the caller's own scope.</summary>
    Write = 2,

    /// <summary>Reaches an external system.</summary>
    External = 3,

    /// <summary>Irreversible. Requires explicit human authorisation, never merely a profile.</summary>
    Destructive = 4,
}
