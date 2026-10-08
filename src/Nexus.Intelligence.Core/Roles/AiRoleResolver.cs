using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Roles;

public sealed class AiRoleResolver : IAiRoleResolver
{
    private readonly IAiRoleStore _store;
    private readonly IModelCatalog _catalog;

    public AiRoleResolver(IAiRoleStore store, IModelCatalog catalog)
    {
        _store = store;
        _catalog = catalog;
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
                    $"Assigned model '{assignment.ModelId}' is not in the catalog or lacks required capabilities " +
                    $"'{assignment.RequiredCapabilities}'; falling through to default model selection.",
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
