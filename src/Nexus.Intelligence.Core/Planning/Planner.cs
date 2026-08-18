using System.Text.Json;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Turns;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Planning;

public sealed class Planner : IPlanner
{
    private const string SchemaInstruction = """
        Decompose the user's objective into a plan. Respond with ONLY a JSON object of this shape,
        no prose and no markdown fences:
        {"steps":[{"id":"string","title":"string","description":"string|null","dependsOn":["string"],"acceptanceCriteria":"string|null"}]}
        """;

    private readonly IModelSelector _modelSelector;
    private readonly IModelGateway _modelGateway;

    public Planner(IModelSelector modelSelector, IModelGateway modelGateway)
    {
        _modelSelector = modelSelector;
        _modelGateway = modelGateway;
    }

    public async Task<PlanPayload> CreatePlanAsync(IntelligenceTurnRequest request, CancellationToken ct = default)
    {
        var modelSelection = await _modelSelector.SelectAsync(TurnIntent.Planning, request.Constraints, ct);

        var invocation = new ModelInvocation
        {
            ModelId = modelSelection.Model.ModelId,
            Messages =
            [
                new ModelMessage { Role = ModelRole.System, Content = SchemaInstruction },
                new ModelMessage { Role = ModelRole.User, Content = request.Input.Text }
            ],
            MaxCost = request.Constraints.MaxCost,
            Identity = new InvocationIdentity(request.TenantId, request.ProductId, request.IdempotencyKey, request.Actor.UserId)
        };

        var result = await _modelGateway.InvokeAsync(invocation, ct);

        return result is { Success: true, Message: not null }
            ? ParsePlan(result.Message.Content)
            : new PlanPayload([]);
    }

    private static PlanPayload ParsePlan(string content)
    {
        try
        {
            using var document = JsonDocument.Parse(ExtractJsonObject(content));

            if (!document.RootElement.TryGetProperty("steps", out var stepsElement) || stepsElement.ValueKind != JsonValueKind.Array)
            {
                return new PlanPayload([]);
            }

            var steps = stepsElement.EnumerateArray().Select(ParseStep).ToList();
            return new PlanPayload(steps);
        }
        catch (JsonException)
        {
            return new PlanPayload([]);
        }
    }

    private static PlanStep ParseStep(JsonElement element)
    {
        var id = element.TryGetProperty("id", out var idEl) && idEl.ValueKind == JsonValueKind.String
            ? idEl.GetString()!
            : Guid.NewGuid().ToString("N");

        var title = element.TryGetProperty("title", out var titleEl) && titleEl.ValueKind == JsonValueKind.String
            ? titleEl.GetString()!
            : string.Empty;

        var description = element.TryGetProperty("description", out var descEl) && descEl.ValueKind == JsonValueKind.String
            ? descEl.GetString()
            : null;

        var dependsOn = element.TryGetProperty("dependsOn", out var depsEl) && depsEl.ValueKind == JsonValueKind.Array
            ? depsEl.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray()
            : [];

        var acceptanceCriteria = element.TryGetProperty("acceptanceCriteria", out var acEl) && acEl.ValueKind == JsonValueKind.String
            ? acEl.GetString()
            : null;

        return new PlanStep
        {
            Id = id,
            Title = title,
            Description = description,
            DependsOn = dependsOn,
            AcceptanceCriteria = acceptanceCriteria
        };
    }

    private static string ExtractJsonObject(string content)
    {
        var start = content.IndexOf('{');
        var end = content.LastIndexOf('}');
        return start >= 0 && end > start ? content[start..(end + 1)] : content;
    }
}
