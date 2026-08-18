using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Turns;

namespace Nexus.Intelligence.Api.Endpoints;

public static class TurnsEndpoints
{
    public static IEndpointRouteBuilder MapTurnsEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapPost("/intelligence/v1/turns", async (
            IntelligenceTurnRequest request,
            ITurnPipeline pipeline,
            CancellationToken ct) =>
        {
            var validationError = TurnRequestValidation.Validate(request);
            if (validationError is not null)
            {
                return validationError;
            }

            var response = await pipeline.ExecuteAsync(request, ct);
            return Results.Ok(response);
        });

        app.MapGet("/intelligence/v1/turns/{turnId}/explanation", async (
            string turnId,
            ITurnTraceStore traceStore,
            CancellationToken ct) =>
        {
            var trace = await traceStore.GetAsync(turnId, ct);

            return trace is null
                ? Results.Problem(
                    statusCode: StatusCodes.Status404NotFound,
                    title: "Unknown turn.",
                    detail: $"No turn trace found for turnId '{turnId}'.")
                : Results.Ok(trace.Decisions);
        });

        return app;
    }
}
