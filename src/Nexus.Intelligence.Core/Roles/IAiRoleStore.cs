namespace Nexus.Intelligence.Core.Roles;

/// <summary>
/// Persistence boundary for roles and their assignments. Mirrors <c>IMemoryStore</c>'s shape: the
/// store owns data, never decisions - resolving a role to a model is the resolver's job. Both
/// entities persist: an <see cref="AiRole"/> (its name and description) and the active
/// <see cref="AiRoleAssignment"/> binding it to a model.
/// </summary>
public interface IAiRoleStore
{
    Task<AiRole?> GetRoleAsync(string roleName, CancellationToken ct = default);
    Task UpsertRoleAsync(AiRole role, CancellationToken ct = default);

    Task<IReadOnlyList<AiRoleAssignment>> ListAsync(CancellationToken ct = default);
    Task<AiRoleAssignment?> GetAsync(string roleName, CancellationToken ct = default);
    Task UpsertAsync(AiRoleAssignment assignment, CancellationToken ct = default);
}
