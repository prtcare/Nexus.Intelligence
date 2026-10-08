using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Roles;

/// <summary>
/// The currently-active configuration for a role: which model (and therefore which provider) serves it,
/// and which capabilities the role requires of that model. Re-assigning a role to a different model is
/// done by upserting a new assignment for the same <see cref="RoleName"/> - swapping a role's
/// provider/model requires only a configuration change, never a code change.
/// </summary>
public sealed record AiRoleAssignment(
    string RoleName,
    string ModelId,
    ModelCapabilities RequiredCapabilities,
    DateTimeOffset AssignedAt);
