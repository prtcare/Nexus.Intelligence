using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Planning;

namespace Nexus.Intelligence.Api.Endpoints;

public static class PlansEndpoints
{
    public static IEndpointRouteBuilder MapPlansEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapPost("/intelligence/v1/plans", async (
            IntelligenceTurnRequest request,
            IPlanner planner,
            CancellationToken ct) =>
        {
            var validationError = TurnRequestValidation.Validate(request);
            if (validationError is not null)
            {
                return validationError;
            }

            var plan = await planner.CreatePlanAsync(request, ct);
            return Results.Ok(plan);
        });

        return app;
    }
}
