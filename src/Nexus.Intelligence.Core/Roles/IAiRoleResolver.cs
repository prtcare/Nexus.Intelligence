namespace Nexus.Intelligence.Core.Roles;

/// <summary>
/// Resolves a named <see cref="AiRole"/> to its assignment and the model that assignment names.
/// </summary>
/// <remarks>
/// <para>
/// <b>W7D TASK 9: the result of this resolution is evidence, and it must never select a route.</b> Before
/// W7D the resolution's <c>Model</c> was merged into <c>TurnConstraints.ModelHint</c> and the model
/// selector preferred it, which made an operator's role configuration a routing instruction the caller
/// could not see and the audit record could not distinguish from a capability-based choice. That path is
/// gone: <c>ModelSelector</c> is deleted, and the live pipeline records this resolution and then asks the
/// W7C router for a route on its own merits.
/// </para>
/// <para>
/// <b>Reconnecting this to routing would restore a bypass, not a feature.</b> The router's request
/// contract refuses a model preference on purpose — see <c>AiRoutingContext</c>, which permits a caller
/// to say how large the work is and forbids it to say which model should serve it. Anything that reads
/// this resolution and narrows the candidate set with it is choosing a model outside governance. An
/// operator who wants a role's expectation to become the outcome expresses that by giving the model a
/// priority in the registry, where it is a routing input rather than a bypass.
/// </para>
/// <para>
/// <b>The lookup still reads the provider catalogue, and that is a known reconciliation gap.</b> The
/// assignment's <c>ModelId</c> is already the registry's own identity — <c>AiModelRegistration</c> names
/// <c>AiRoleAssignment</c> as one of the places that identity appears — so the stored value needs no
/// adaptation. What is not yet reconciled is the <em>lookup</em>: the governed inventory is
/// <c>IAiModelRegistry</c>, which is fail-closed, and resolving a role against it in a default estate
/// would make every role unresolvable rather than more correct. That change needs a decision about what a
/// role assignment means when the registry offers nothing, and it is deliberately not taken here.
/// </para>
/// <para>
/// <b>This is informational, so the change above would be invisible to the live path either way.</b> No
/// routing code reads the resolved model, so the gap is a reporting inaccuracy rather than a governance
/// hole — which is why it is recorded rather than rushed.
/// </para>
/// </remarks>
public interface IAiRoleResolver
{
    /// <summary>Resolves a role to its assignment and the model that assignment names.</summary>
    Task<AiRoleResolution> ResolveAsync(string roleName, CancellationToken ct = default);
}
