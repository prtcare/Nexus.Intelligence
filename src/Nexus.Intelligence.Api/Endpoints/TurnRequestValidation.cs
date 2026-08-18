using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Api.Endpoints;

internal static class TurnRequestValidation
{
    public static IResult? Validate(IntelligenceTurnRequest request)
    {
        var errors = new Dictionary<string, string[]>();

        if (string.IsNullOrWhiteSpace(request.TenantId))
        {
            errors["tenantId"] = ["TenantId is required."];
        }

        if (string.IsNullOrWhiteSpace(request.ProductId))
        {
            errors["productId"] = ["ProductId is required."];
        }

        if (string.IsNullOrWhiteSpace(request.IdempotencyKey))
        {
            errors["idempotencyKey"] = ["IdempotencyKey is required."];
        }

        if (string.IsNullOrWhiteSpace(request.Input?.Text))
        {
            errors["input.text"] = ["Input.Text is required."];
        }

        return errors.Count > 0
            ? Results.ValidationProblem(errors, title: "The turn request is missing required fields.")
            : null;
    }
}
