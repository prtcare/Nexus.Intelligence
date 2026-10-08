using System.Collections.Concurrent;

namespace Nexus.Intelligence.Core.Roles;

/// <summary>
/// In-memory, <c>ConcurrentDictionary</c>-backed role store - the sibling pattern to
/// <see cref="Nexus.Intelligence.Memory.InMemoryMemoryStore"/>. Both a role's definition and its
/// active assignment persist: the last-upserted <see cref="AiRole"/> for a name and the last-upserted
/// <see cref="AiRoleAssignment"/> for a <see cref="AiRoleAssignment.RoleName"/> are the current state.
/// </summary>
public sealed class InMemoryAiRoleStore : IAiRoleStore
{
    private readonly ConcurrentDictionary<string, AiRole> _roles = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, AiRoleAssignment> _assignments = new(StringComparer.Ordinal);

    public InMemoryAiRoleStore(
        IEnumerable<AiRole>? seedRoles = null,
        IEnumerable<AiRoleAssignment>? seedAssignments = null)
    {
        if (seedRoles is not null)
        {
            foreach (var role in seedRoles)
            {
                _roles[role.Name] = role;
            }
        }

        if (seedAssignments is not null)
        {
            foreach (var assignment in seedAssignments)
            {
                _assignments[assignment.RoleName] = assignment;
            }
        }
    }

    public Task<AiRole?> GetRoleAsync(string roleName, CancellationToken ct = default)
    {
        _roles.TryGetValue(roleName, out var role);
        return Task.FromResult(role);
    }

    public Task UpsertRoleAsync(AiRole role, CancellationToken ct = default)
    {
        _roles[role.Name] = role;
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<AiRoleAssignment>> ListAsync(CancellationToken ct = default)
    {
        IReadOnlyList<AiRoleAssignment> snapshots = _assignments.Values.ToList();
        return Task.FromResult(snapshots);
    }

    public Task<AiRoleAssignment?> GetAsync(string roleName, CancellationToken ct = default)
    {
        _assignments.TryGetValue(roleName, out var assignment);
        return Task.FromResult(assignment);
    }

    public Task UpsertAsync(AiRoleAssignment assignment, CancellationToken ct = default)
    {
        _assignments[assignment.RoleName] = assignment;
        return Task.CompletedTask;
    }
}
