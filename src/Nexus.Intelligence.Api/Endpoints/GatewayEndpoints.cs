using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Api.Endpoints;

/// <summary>
/// The public AI Gateway surface: the routes a Forge or Product consumer calls.
/// </summary>
/// <remarks>
/// <para>
/// <b>Every handler here is a call to a port and nothing else.</b> There is no routing, no model
/// selection, no provider lookup, no registry read and no credential anywhere in this file, because
/// the layers that own those decisions are below the boundary this file serves. A handler that
/// inspected a registry to enrich a response would put registry access in the transport layer, which is
/// one added field away from a caller-facing type that carries the registry's contents — the same
/// argument <c>AiGatewayAvailabilityProjection</c> makes for projecting availability below the
/// transport rather than inside it.
/// </para>
/// <para>
/// <b>The version is stamped on every response from one place.</b>
/// <see cref="Stamp"/> is called by every route, including the failure paths, so a caller cannot
/// receive an answer from this Head that does not say which contract answered it. A per-route header
/// assignment would be one route away from being forgotten.
/// </para>
/// </remarks>
public static class GatewayEndpoints
{
    /// <summary>Maps the AI Gateway routes.</summary>
    public static IEndpointRouteBuilder MapGatewayEndpoints(this IEndpointRouteBuilder app)
    {
        // The capability invocation. The body is the semantic contract itself rather than a wire DTO
        // invented here, so the shape a consumer sends is the shape the contract defines and there is no
        // third definition of it to keep in step with the two that already exist.
        app.MapPost($"{AiGatewayContract.RoutePrefix}/invoke", async (
            AiCapabilityRequest request,
            IAiCapabilityClient client,
            HttpContext context,
            CancellationToken ct) =>
        {
            Stamp(context);

            var refusal = VersionRefusal(context);

            if (refusal is not null)
            {
                return refusal;
            }

            // Returns rather than throws for every AI-side failure, per IAiCapabilityClient: the
            // response body carries the typed failure and the status code stays 200. A consumer that
            // treated a policy refusal as a transport error would retry a decision that has already
            // been taken.
            return Results.Ok(await client.InvokeAsync(request, ct));
        });

        // What this Head will do, in governance terms. Never what it rents - see
        // IAiCapabilityClient.ListCapabilitiesAsync.
        app.MapGet($"{AiGatewayContract.RoutePrefix}/capabilities", async (
            IAiCapabilityClient client,
            HttpContext context,
            CancellationToken ct) =>
        {
            Stamp(context);

            return Results.Ok(await client.ListCapabilitiesAsync(ct));
        });

        // The cross-Head availability contract. A caller asks this before it knows anything else about
        // the Head, which is why the version is carried in the body here as well as in the header.
        app.MapGet($"{AiGatewayContract.RoutePrefix}/availability", (
            IAiGatewayAvailabilitySource availability,
            HttpContext context) =>
        {
            Stamp(context);

            return Results.Ok(availability.Read());
        });

        // Braces doubled: this is an interpolated string, so a single {capability} here would be read as
        // an interpolation of a variable rather than as a route parameter.
        app.MapGet($"{AiGatewayContract.RoutePrefix}/availability/{{capability}}", (
            string capability,
            IAiGatewayAvailabilitySource availability,
            HttpContext context) =>
        {
            Stamp(context);

            // A malformed identifier is refused before it is looked up, and refused differently from an
            // unknown one. CapabilityId.TryParse rather than Parse because Parse throws, and a caller's
            // typo arriving as a FormatException would surface as a 500 — a server error reported for a
            // defect in the request, which is the failure mode that teaches a consumer to retry.
            if (!CapabilityId.TryParse(capability, out var parsed, out var reason))
            {
                return Results.Problem(
                    statusCode: StatusCodes.Status400BadRequest,
                    title: "Malformed capability identifier.",
                    detail: reason);
            }

            var entry = availability.Read(parsed!);

            // Absent rather than unavailable. An unrecognised capability is a caller asking for
            // something that does not exist, and telling it the service is down would send it to retry a
            // request that can never succeed.
            return entry is null
                ? Results.Problem(
                    statusCode: StatusCodes.Status404NotFound,
                    title: "Unknown capability.",
                    detail: $"This AI Head does not register a capability named '{capability}'.")
                : Results.Ok(entry);
        });

        return app;
    }

    /// <summary>
    /// Refuses a caller that stated a contract version this Head does not serve.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Only a caller that stated a version is judged on it.</b>
    /// <see cref="AiGatewayContract.VersionHeader"/> is documented as the header this Head answers
    /// with, so a consumer is entitled not to send one; refusing an absent header would break every
    /// caller written against the published contract, which is how a version strategy becomes a
    /// version outage.
    /// </para>
    /// <para>
    /// A caller that <em>did</em> state a version and is incompatible is refused, and refused before
    /// anything is executed. The alternative — serving it anyway — means the skew is discovered by the
    /// consumer misreading a response, which is precisely the failure a version strategy exists to
    /// convert into one clear answer.
    /// </para>
    /// </remarks>
    private static IResult? VersionRefusal(HttpContext context)
    {
        if (!context.Request.Headers.TryGetValue(AiGatewayContract.VersionHeader, out var stated)
            || stated.Count == 0)
        {
            return null;
        }

        var callerVersion = stated[0];

        if (AiGatewayContract.IsCompatibleWith(callerVersion))
        {
            return null;
        }

        return Results.Problem(
            statusCode: StatusCodes.Status409Conflict,
            title: "Incompatible AI Gateway contract version.",
            detail: $"This Head serves contract version {AiGatewayContract.Version} and the caller stated "
                + $"'{callerVersion}'. Nothing was executed. A change of major version is served "
                + "alongside the version it replaces rather than in place of it, so this caller should "
                + "address the route prefix carrying the major version it was built against.");
    }

    /// <summary>States the served contract version on a response, whatever the response turns out to be.</summary>
    private static void Stamp(HttpContext context)
        => context.Response.Headers[AiGatewayContract.VersionHeader] = AiGatewayContract.Version;
}
