using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Roles;

public sealed class AiRoleResolver : IAiRoleResolver
{
    private readonly IAiRoleStore _store;
    private readonly IModelCatalog _catalog;
    private readonly IAiModelRegistry _registry;

    /// <summary>
    /// W10.7A GATE 2. The two model surfaces have DIFFERENT AUTHORITATIVE ROLES, and this type must
    /// consult both — in that order of authority.
    ///
    /// <para><b><see cref="IModelCatalog"/> — the Provider Model Catalogue.</b> The models the provider
    /// IMPLEMENTATION supports. Presence means <c>PROVIDER_SUPPORTED</c>. It does not authorize Nexus
    /// routing, and it is used here only as a capability constraint.</para>
    ///
    /// <para><b><see cref="IAiModelRegistry"/> — the governed AI Model Registry.</b> The models Nexus
    /// AI Head may route to. Presence means <c>NEXUS_ROUTABLE</c>. <b>This is the authority that decides
    /// whether a role may resolve to a model at all.</b></para>
    ///
    /// <para><b>These two are never interchangeable, and are never called "the model catalogue".</b> See
    /// <c>docs/MODEL_AUTHORITY.md</c>.</para>
    ///
    /// <para><b>Why the second dependency is not optional.</b> Before this change the resolver read
    /// only the provider catalogue, so a role assigned <c>openai:gpt-4o</c> — present in the provider
    /// catalogue, absent from the governed registry — resolved successfully to a model the router
    /// cannot route. A role that names an unroutable model is a promise the estate cannot keep, and
    /// nothing downstream refused it: the failure surfaced later, as a routing failure, far from the
    /// decision that caused it.</para>
    /// </summary>
    public AiRoleResolver(IAiRoleStore store, IModelCatalog catalog, IAiModelRegistry registry)
    {
        _store = store;
        _catalog = catalog;
        _registry = registry;
    }

    public async Task<AiRoleResolution> ResolveAsync(string roleName, CancellationToken ct = default)
    {
        var role = await _store.GetRoleAsync(roleName, ct);

        if (role is null)
        {
            return new AiRoleResolution(
                null,
                null,
                null,
                new DecisionTrace(
                    $"AiRole '{roleName}' is not registered",
                    $"No AiRole is stored for role '{roleName}'; falling through to default model selection.",
                    []));
        }

        var assignment = await _store.GetAsync(role.Name, ct);

        if (assignment is null)
        {
            return new AiRoleResolution(
                role,
                null,
                null,
                new DecisionTrace(
                    $"AiRole '{role.Name}' has no active assignment",
                    $"No AiRoleAssignment is configured for role '{role.Name}'; falling through to default model selection.",
                    []));
        }

        var all = await _catalog.ListAsync(ModelQuery.Any, ct);
        var model = all.FirstOrDefault(m =>
            m.ModelId == assignment.ModelId &&
            (m.Capabilities & assignment.RequiredCapabilities) == assignment.RequiredCapabilities);

        if (model is null)
        {
            return new AiRoleResolution(
                role,
                assignment,
                null,
                new DecisionTrace(
                    $"AiRole '{role.Name}' assignment is not resolvable",
                    $"Assigned model '{assignment.ModelId}' is not in the Provider Model Catalogue or lacks required " +
                    $"capabilities '{assignment.RequiredCapabilities}'; falling through to default model selection.",
                    []));
        }

        // ---- GATE 2: the governed registry decides ROUTABILITY. Provider support does not.
        //
        // The provider catalogue answers "can this provider serve this model?". The governed registry
        // answers "may Nexus route to it?". Only the second authorizes a resolution, and a resolver that
        // skipped it would return a model the router must then refuse — moving the failure away from the
        // decision that caused it.
        if (!_registry.TryGetModel(model.ModelId, out _))
        {
            return new AiRoleResolution(
                role,
                assignment,
                null,
                new DecisionTrace(
                    $"AiRole '{role.Name}' assignment is PROVIDER_SUPPORTED_NOT_REGISTERED_FOR_ROUTING",
                    $"Assigned model '{assignment.ModelId}' is present in the Provider Model Catalogue but absent "
                    + "from the governed AI Model Registry, so Nexus may not route to it. Provider support does not "
                    + "authorize routing; the model must be added to the governed registry before a role can resolve "
                    + "to it. Falling through to default model selection.",
                    []));
        }

        return new AiRoleResolution(
            role,
            assignment,
            model,
            new DecisionTrace(
                $"Resolved AiRole '{role.Name}' to model '{model.ModelId}'",
                $"Role assignment requires capabilities '{assignment.RequiredCapabilities}'; '{model.ModelId}' satisfies them.",
                []));
    }
}
