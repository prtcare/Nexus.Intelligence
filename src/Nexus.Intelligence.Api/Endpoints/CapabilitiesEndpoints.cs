using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Api.Endpoints;

/// <summary>
/// The retired capability-discovery route, kept mapped so that it can refuse rather than disappear.
/// </summary>
/// <remarks>
/// <para>
/// <b>What this route used to return, and why it could not keep returning it.</b>
/// <c>GET /intelligence/v1/capabilities</c> answered with the model catalogue — model identifiers and
/// their vendors — alongside the agent identifiers, the tool identifiers, and the AI assembly's own
/// version. Three of those are AI-internal inventory and the fourth is an implementation build
/// number. TASK 8 forbids Forge inspecting registry internals, TASK 13 forbids exposing raw provider
/// configuration and AI registry surfaces to ordinary callers, TASK 14 forbids coupling external
/// callers to AI implementation assembly versions, and this single handler did all three. The
/// semantic replacement is <c>GET /intelligence/gateway/v1/capabilities</c>, which answers with
/// capability identifiers and their governance facts and with no model, vendor, agent, tool or
/// assembly version at all.
/// </para>
/// <para>
/// <b>The route is <c>410</c> rather than re-pointed, and the alternative was considered.</b> The
/// obvious repair is to serve the semantic listing here instead: keep the status code, keep the
/// route, swap the body. It was rejected because the response type is a <em>shape</em>, and the shape
/// is what a consumer deserialises. A caller built against <c>Models</c>, <c>AgentIds</c> and
/// <c>ToolIds</c> would receive a document with those three members present and empty — which is not
/// an error to it, it is an estate that has no models and no tools. It would carry on, silently, with
/// the wrong belief. An explicit refusal naming the replacement cannot be mistaken for data, and the
/// route prefix in the replacement names the contract version a consumer must rebuild against.
/// </para>
/// <para>
/// <b>Keeping the route mapped is the point; deleting the mapping would be worse.</b> An unmapped
/// route answers <c>404</c> from routing itself, which is indistinguishable from a typo, carries no
/// replacement address, and tells a consumer nothing about whether the capability ever existed. The
/// handler below exists solely to say "this moved, here is where, and this is why" — the one answer a
/// silently narrowed body cannot give.
/// </para>
/// <para>
/// <b>The response types are deleted rather than left unused.</b> <c>CapabilitiesResponse</c> and
/// <c>ModelSummary</c> were the leak in type form: any later lane that wanted to publish a model list
/// would have found a public record already shaped for it, named as though it were the capabilities
/// contract. A leak that is unrepresentable is a leak that cannot be reintroduced by accident.
/// </para>
/// <para>
/// <b>No compatibility window is offered, and that is deliberate.</b>
/// <see cref="AiGatewayContract"/>'s rule is that a breaking change is a new major version served
/// alongside the old one rather than in place of it. That rule exists so a consumer is never upgraded
/// on the Head's schedule. It does not extend to a response whose contents are an exposure: serving
/// the old shape alongside the new one would mean continuing to publish the model catalogue, and
/// "compatible" is not a defence for a disclosure. The rule protects consumers from change, not from
/// remediation.
/// </para>
/// </remarks>
public static class CapabilitiesEndpoints
{
    /// <summary>The route that was retired, retained so it can answer with the replacement.</summary>
    public const string RetiredRoute = "/intelligence/v1/capabilities";

    /// <summary>The route that supersedes it.</summary>
    public static string ReplacementRoute => $"{AiGatewayContract.RoutePrefix}/capabilities";

    /// <summary>Maps the retired route so that it answers with a refusal rather than a 404.</summary>
    public static IEndpointRouteBuilder MapCapabilitiesEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet(RetiredRoute, (HttpContext context) =>
        {
            // Stated on the way out as well as on the way in. A consumer that reaches this route is
            // mid-migration, and the version it is being told to move to is the single most useful thing
            // this response can carry.
            context.Response.Headers[AiGatewayContract.VersionHeader] = AiGatewayContract.Version;

            context.Response.Headers.Location = ReplacementRoute;

            return Results.Problem(
                statusCode: StatusCodes.Status410Gone,
                title: "This capability endpoint has been retired.",
                detail: $"It returned the model catalogue, the agent and tool identifiers, and the AI "
                    + $"assembly version. All four are AI Head internals that a caller is not entitled to, "
                    + $"so the route was not narrowed but replaced. Read {ReplacementRoute} instead, which "
                    + $"answers with capability identifiers and their governance facts under contract "
                    + $"version {AiGatewayContract.Version}.");
        });

        return app;
    }
}
