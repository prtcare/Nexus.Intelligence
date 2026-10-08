using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;

namespace Nexus.Intelligence.Api.Endpoints;

/// <summary>
/// The AI operations surface: the read-only routes an operator — and later Atlas — reads the estate
/// through.
/// </summary>
/// <remarks>
/// <para>
/// <b>It is served under its own prefix, and the separation is load-bearing rather than cosmetic.</b>
/// The gateway routes under <see cref="AiGatewayContract.RoutePrefix"/> are a <em>caller</em> surface:
/// every type they return is provider-neutral, and TASK 7 requires that a Product cannot read raw
/// provider health through them. The routes below are an <em>operator</em> surface: they name
/// providers, models, health states, spend and routing rejections, because that is what an operator
/// surface is for and because <see cref="AiExecutionOperationsView"/>'s own remarks already say a
/// Product does not receive it. Two prefixes make that difference a property of the URL rather than a
/// property of the response body, so a later edit cannot publish an operator document through a
/// caller's route without the route itself reading wrong.
/// </para>
/// <para>
/// <b>There is no authorization layer in this estate, and that is a real gap rather than a
/// detail.</b> These routes are mapped exactly as openly as the turn routes beside them. The
/// difference is what is behind them: an operator surface that names providers, models and spend is
/// worth more to an unauthenticated caller than a turn endpoint is. Nothing here is secret — no
/// credential is read, held or returned by any handler below, and the audit records carry content
/// hashes rather than content — but "not secret" is not the same as "not sensitive", and the honest
/// statement is that this surface requires an authorization layer this estate does not yet implement.
/// It is recorded as a carry-forward rather than closed here, because inventing an ad-hoc scheme in a
/// transport file is how an estate ends up with two of them.
/// </para>
/// <para>
/// <b>Every handler is a read.</b> TASK 15 requires the operations read APIs to be read-only and
/// requires that to be proven rather than asserted, so no handler below takes a write port: the
/// container's <c>IAiUsageLedger</c> has a <c>Record</c> method and <c>IAiHealthSnapshotStore</c> has
/// a <c>Publish</c>, and neither is reachable from this file. The proof is a test over the composed
/// route table, not a reading of this paragraph.
/// </para>
/// <para>
/// <b>The health read is projected rather than returned.</b> <see cref="AiHealthSnapshot"/> keys its
/// model states by a <c>(ModelId, ProviderId)</c> tuple, which <c>System.Text.Json</c> cannot
/// serialise as a dictionary key — it throws at response time, on the first estate whose snapshot is
/// not empty, which is every estate that works. The projection below is therefore the difference
/// between a route that works and one that 500s in production while passing a test written against an
/// empty snapshot; a flat row per target is also the shape a reader can actually scan.
/// </para>
/// </remarks>
public static class OperationsEndpoints
{
    /// <summary>The prefix every operations route is served under.</summary>
    /// <remarks>
    /// Versioned like the gateway's, and for the same reason: an operator tool built against this
    /// shape must be able to tell which shape answered it. It is deliberately <em>not</em> derived
    /// from <see cref="AiGatewayContract.Version"/>. A provider-neutral caller contract and an
    /// operator read surface change for unrelated reasons, and tying them together would force a
    /// major version of the caller contract every time an operator column moved.
    /// </remarks>
    public const string RoutePrefix = "/intelligence/operations/v1";

    /// <summary>Maps the read-only AI operations routes.</summary>
    public static IEndpointRouteBuilder MapOperationsEndpoints(this IEndpointRouteBuilder app)
    {
        // Execution status. The single-execution read, and the one route whose absence is answered as
        // an absence: an execution identifier this Head has no record of is a 404, not an empty view.
        app.MapGet($"{RoutePrefix}/executions/{{executionId}}", (
            string executionId,
            IAiOperationsReadModel operations) =>
        {
            var view = operations.Execution(executionId);

            return view is null
                ? Results.Problem(
                    statusCode: StatusCodes.Status404NotFound,
                    title: "Unknown execution.",
                    detail: $"This AI Head has no record of an execution '{executionId}'. The identity is "
                        + "per-execution and is not the caller's request identifier; a request identifier "
                        + "resolves through the recent-executions read instead.")
                : Results.Ok(view);
        });

        // Recent executions. The scalar filters only - see the remarks on the class, and note that the
        // read model accepts status and failure-category sets this transport does not expose.
        app.MapGet($"{RoutePrefix}/executions", (
            IAiOperationsReadModel operations,
            string? capability = null,
            string? providerId = null,
            string? modelId = null,
            string? productId = null,
            string? tenantId = null,
            string? requestId = null,
            DateTimeOffset? from = null,
            DateTimeOffset? to = null,
            bool? usedFallback = null,
            int? limit = null) =>
        {
            if (!TryCapability(capability, out var parsedCapability, out var refusal))
            {
                return refusal!;
            }

            return Results.Ok(operations.Executions(new AiOperationsQuery
            {
                Capability = parsedCapability,
                ProviderId = providerId,
                ModelId = modelId,
                ProductId = productId,
                TenantId = tenantId,
                RequestId = requestId,
                From = from,
                To = to,
                UsedFallback = usedFallback,
                Limit = limit,
            }));
        });

        // Usage summary. Grouped, because "how much did we use" is only answerable against a dimension.
        app.MapGet($"{RoutePrefix}/usage", (
            IAiUsageLedger usage,
            string? capability = null,
            string? providerId = null,
            string? modelId = null,
            string? productId = null,
            string? tenantId = null,
            DateTimeOffset? from = null,
            DateTimeOffset? to = null,
            AiUsageGroupBy groupBy = AiUsageGroupBy.Capability) =>
        {
            if (!TryCapability(capability, out var parsedCapability, out var refusal))
            {
                return refusal!;
            }

            return Results.Ok(usage.Query(new AiUsageQuery
            {
                Capability = parsedCapability,
                ProviderId = providerId,
                ModelId = modelId,
                ProductId = productId,
                TenantId = tenantId,
                From = from,
                To = to,
                GroupBy = groupBy,
            }));
        });

        // Cost summary. The reconciliation of prediction against measurement, which is a different
        // question from the usage totals above and is why it is a different route rather than a member.
        app.MapGet($"{RoutePrefix}/cost", (
            IAiCostLedger cost,
            string? capability = null,
            string? providerId = null,
            string? modelId = null,
            string? productId = null,
            DateTimeOffset? from = null,
            DateTimeOffset? to = null) =>
        {
            if (!TryCapability(capability, out var parsedCapability, out var refusal))
            {
                return refusal!;
            }

            return Results.Ok(cost.Query(new AiCostQuery
            {
                Capability = parsedCapability,
                ProviderId = providerId,
                ModelId = modelId,
                ProductId = productId,
                From = from,
                To = to,
            }));
        });

        // Provider and model health, as the estate's own operators see it. Projected to flat rows -
        // see the class remarks for why the snapshot's own shape cannot be returned.
        app.MapGet($"{RoutePrefix}/health", (IAiHealthSnapshotStore health) =>
        {
            var snapshot = health.Current;

            var rows = new List<AiHealthRow>();

            foreach (var provider in snapshot.Providers)
            {
                rows.Add(new AiHealthRow(provider.Key, null, provider.Value));
            }

            foreach (var model in snapshot.Models)
            {
                rows.Add(new AiHealthRow(model.Key.ProviderId, model.Key.ModelId, model.Value));
            }

            return Results.Ok(new AiHealthReport(
                snapshot.TakenAt,
                snapshot.Source,
                [.. rows.OrderBy(r => r.ProviderId, StringComparer.Ordinal)
                    .ThenBy(r => r.ModelId, StringComparer.Ordinal)]));
        });

        // Observed reliability. Null success rates survive the wire as null, deliberately: an
        // unobserved route reported as a rate of zero is a new route the estate refuses until it has
        // been used.
        app.MapGet($"{RoutePrefix}/reliability", (IAiReliabilityHistory reliability)
            => Results.Ok(reliability.All()));

        // W7G-R: each route's observed record beside the circuit state that record has produced.
        //
        // A route of its own rather than a field added to the read above, because the read above is an
        // existing surface with an existing shape and W7G-R's standing requirement is that a consumer
        // of a working surface does not have to change. This route is new, so nothing that read the old
        // one is affected by it.
        //
        // The pair is the point: evidence without the circuit leaves a route that has been stopped
        // looking identical to one that is being used, and the circuit without the evidence leaves a
        // stopped route looking arbitrary. Published together, one row answers "what has this route
        // done" and "what is the estate doing about it" at once — and the failures that opened a circuit
        // are visible on the same row that reports the route has since recovered.
        app.MapGet($"{RoutePrefix}/circuits", (
            IAiReliabilityHistory reliability,
            IAiCircuitBreaker circuit,
            TimeProvider time) =>
        {
            var now = time.GetUtcNow();

            return Results.Ok(reliability.All()
                .Select(evidence => new AiRouteOperationsRow
                {
                    Evidence = evidence,
                    Circuit = circuit.For(evidence.ProviderId, evidence.ModelId, now),
                })
                .ToArray());
        });

        // Audit lookup by execution. The evidence itself, resolvable under authority.
        app.MapGet($"{RoutePrefix}/audit/{{executionId}}", (
            string executionId,
            IAiAuditReader audit) =>
        {
            var record = audit.Find(executionId);

            return record is null
                ? Results.Problem(
                    statusCode: StatusCodes.Status404NotFound,
                    title: "No audit record for this execution.",
                    detail: "An execution that never reached the audit emitter has no evidence to read. "
                        + "This is not the same finding as an execution that failed.")
                : Results.Ok(record);
        });

        // The most recent evidence, bounded. A limit is required rather than defaulted here even though
        // the port would answer: "recent" with no bound is a query whose response size is the estate's
        // uptime.
        app.MapGet($"{RoutePrefix}/audit", (IAiAuditReader audit, int? limit = null) =>
            Results.Ok(audit.Recent(Math.Clamp(limit ?? 50, 1, 500))));

        return app;
    }

    /// <summary>
    /// Parses the optional capability filter, refusing a malformed one rather than ignoring it.
    /// </summary>
    /// <remarks>
    /// <c>CapabilityId.TryParse</c> rather than <c>Parse</c>, and a refusal rather than a null. A filter
    /// that failed to parse and was silently dropped would widen the read to the whole estate while the
    /// caller believed it had been narrowed — the one direction of error that makes an operator act on
    /// a number that is not about what they asked. <c>Parse</c> is worse still: it throws, and a
    /// caller's typo would surface as a 500.
    /// </remarks>
    private static bool TryCapability(string? candidate, out CapabilityId? capability, out IResult? refusal)
    {
        capability = null;
        refusal = null;

        if (candidate is null)
        {
            return true;
        }

        if (CapabilityId.TryParse(candidate, out var parsed, out var reason))
        {
            capability = parsed;
            return true;
        }

        refusal = Results.Problem(
            statusCode: StatusCodes.Status400BadRequest,
            title: "Malformed capability identifier.",
            detail: reason);

        return false;
    }
}

/// <summary>
/// One row of the operator health read: a provider, and optionally one of its models.
/// </summary>
/// <remarks>
/// A row with no <see cref="ModelId"/> is the provider-wide state; a row with one is that model's own
/// state, which may differ from its provider's. Flattened from
/// <see cref="AiHealthSnapshot"/>'s two dictionaries because
/// <see cref="AiHealthSnapshot.Models"/> is keyed by a tuple and <c>System.Text.Json</c> refuses to
/// serialise a non-string dictionary key — at response time, on the first non-empty snapshot.
/// </remarks>
public sealed record AiHealthRow(string ProviderId, string? ModelId, AiModelHealthState State);

/// <summary>
/// One row of the operator reliability read: what a route has been observed to do, and what the estate
/// has decided to do about it.
/// </summary>
/// <remarks>
/// <para>
/// <b>The pair is the point.</b> <see cref="Evidence"/> without <see cref="Circuit"/> leaves a route
/// that has been stopped looking identical to one that is being used — both report the same attempts
/// and the same rate. <see cref="Circuit"/> without <see cref="Evidence"/> leaves a stopped route
/// looking arbitrary. Published together, a row answers both questions at once, and the failures that
/// opened a circuit are visible on the same row that says the route has since recovered.
/// </para>
/// <para>
/// <b>An operator surface, and it names providers.</b> This is served under the operations prefix,
/// never under the gateway prefix, for the reason the file's own remarks give: a Product does not
/// receive this document. It carries no credential and no provider error text — a failure on
/// <see cref="AiReliabilityEvidence"/> is a member of a closed vocabulary.
/// </para>
/// </remarks>
public sealed record AiRouteOperationsRow
{
    /// <summary>What the estate has observed about this route.</summary>
    public required AiReliabilityEvidence Evidence { get; init; }

    /// <summary>Whether the estate is using it, testing it, or has stopped calling it.</summary>
    public required AiCircuitSnapshot Circuit { get; init; }
}

/// <summary>The operator health read: when it was taken, by what, and one row per target.</summary>
/// <remarks>
/// <see cref="TakenAt"/> and <see cref="Source"/> are carried because a health row without them is a
/// claim with no age and no author, and an operator reading one cannot tell a probe that just ran from
/// a snapshot seeded at startup.
/// </remarks>
public sealed record AiHealthReport(
    DateTimeOffset TakenAt,
    string Source,
    IReadOnlyList<AiHealthRow> Targets);
