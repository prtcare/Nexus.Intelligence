using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Roles;

/// <summary>
/// The outcome of resolving a named <see cref="AiRole"/> against its stored assignment and the model
/// catalog.
/// </summary>
/// <remarks>
/// <see cref="Role"/> is null only when the role was never registered in the store. <see cref="Model"/> is
/// null when the role has no assignment, or when the assigned model is not currently resolvable.
/// <para>
/// <b>W7D: this record reports, it does not route.</b> The caller no longer falls through to a model
/// selection path, because the live path no longer has one — there is a single routing path and it is the
/// W7C router, which does not accept a preference. The pipeline records this resolution for the audit
/// trail and, where an assignment names a model, reports it against the route the registry chose. See
/// <see cref="IAiRoleResolver"/> for why reconnecting this to routing would restore a bypass.
/// </para>
/// </remarks>
public sealed record AiRoleResolution(
    AiRole? Role,
    AiRoleAssignment? Assignment,
    ModelDescriptor? Model,
    DecisionTrace Decision);
