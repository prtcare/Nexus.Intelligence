namespace Nexus.Intelligence.Core.Roles;

/// <summary>A named AI interaction role. <see cref="Name"/> is the lookup key for the role's active model assignment.</summary>
public sealed record AiRole(string Name, string Description)
{
    /// <summary>Well-known default role used by the current single caller (Developer Chat).</summary>
    public const string DefaultRoleName = "Discussion";
}
