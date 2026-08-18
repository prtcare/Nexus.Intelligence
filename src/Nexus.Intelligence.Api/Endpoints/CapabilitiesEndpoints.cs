using Nexus.Intelligence.Agents.Abstractions;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Api.Endpoints;

public static class CapabilitiesEndpoints
{
    public static IEndpointRouteBuilder MapCapabilitiesEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/intelligence/v1/capabilities", async (
            IModelCatalog modelCatalog,
            IAgentRegistry agentRegistry,
            IToolCatalog toolCatalog,
            CancellationToken ct) =>
        {
            var models = await modelCatalog.ListAsync(ModelQuery.Any, ct);
            var tools = await toolCatalog.ListAsync(ct);

            var response = new CapabilitiesResponse(
                models.Select(m => new ModelSummary(m.ModelId, m.Vendor, m.Capabilities)).ToArray(),
                agentRegistry.GetAll().Select(a => a.Metadata.Id).ToArray(),
                tools.Select(t => t.ToolId).ToArray(),
                typeof(IntelligenceTurnRequest).Assembly.GetName().Version?.ToString() ?? "0.0.0");

            return Results.Ok(response);
        });

        return app;
    }
}

public sealed record CapabilitiesResponse(
    IReadOnlyList<ModelSummary> Models,
    IReadOnlyList<string> AgentIds,
    IReadOnlyList<string> ToolIds,
    string ContractVersion);

public sealed record ModelSummary(string ModelId, string Vendor, ModelCapabilities Capabilities);
