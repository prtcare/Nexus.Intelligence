using Nexus.Intelligence.Api.ResultReports;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Turns;

namespace Nexus.Intelligence.Api.Endpoints;

public static class ResultsEndpoints
{
    public static IEndpointRouteBuilder MapResultsEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapPost("/intelligence/v1/results", async (
            ResultReport report,
            ITurnTraceStore traceStore,
            IResultReportStore resultStore,
            CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(report.TurnId))
            {
                return Results.ValidationProblem(
                    new Dictionary<string, string[]> { ["turnId"] = ["TurnId is required."] },
                    title: "The result report is missing required fields.");
            }

            var trace = await traceStore.GetAsync(report.TurnId, ct);
            if (trace is null)
            {
                return Results.Problem(
                    statusCode: StatusCodes.Status404NotFound,
                    title: "Unknown turn.",
                    detail: $"No turn trace found for turnId '{report.TurnId}'.");
            }

            await resultStore.AddAsync(report, ct);
            return Results.Ok();
        });

        return app;
    }
}
