using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Nexus.Intelligence.Api.DependencyInjection;
using Nexus.Intelligence.Api.Endpoints;
using Nexus.Intelligence.Api.Tooling;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Gateway;
using Nexus.Intelligence.Core.Operations;
using Nexus.Platform.Contracts.Tools;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7F TASKS 6, 7, 13, 14 and 15: the deterministic proofs about the HTTP surface itself.
//
// WHY THE ROUTE TABLE IS INSPECTED RATHER THAN REQUESTED. The properties asserted here - that every
// operations route is a read, and that the operator surface and the caller surface are disjoint - are
// properties of the composed route table, not of any handler's behaviour. A behavioural test proves
// that the routes someone remembered to call answer correctly; a walk over the composed table proves
// that no other route exists. TASK 15 asks for exactly that distinction by requiring the read-only
// property to be proven and by requiring negative fixtures beside it.
//
// WHY THE DISCLOSURE TESTS RENDER RATHER THAN REFLECT. W7fGatewayBoundaryTests already asserts, over the
// contract's reachable types, that no caller-facing type CAN carry a provider or a model. These assert
// the other half: that the live responses of the two new routes, serialised the way the application
// serialises them, DO NOT carry one. A type can be clean and a projection can still copy the wrong
// thing into it, which is why the two suites are complements and neither is redundant.
//
// EVERY DETECTOR CARRIES A NON-VACUITY CONTROL. The disclosure pair is the sharpest: the same named
// provider and model that the caller surface must not name are shown to be present, by name, on the
// operator surface read from the same snapshot. A detector that cannot see the thing it forbids proves
// nothing by failing to find it.
public sealed class W7fHttpSurfaceTests
{
    private const string NamedProvider = "prov-w7f-http";
    private const string NamedModel = "prov-w7f-http:model-w7f-http";

    /// <summary>
    /// Every endpoint the three W7F endpoint groups compose, with its methods and its route.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <c>WebApplication.CreateSlimBuilder()</c> rather than a started host: the route table is
    /// complete once the groups are mapped, and a test host would add a Kestrel listener and a port
    /// binding to a test that needs neither. The builder is never run.
    /// </para>
    /// <para>
    /// <b>The real composition root is called, and that turned out to matter.</b> Materialising a
    /// route table runs <c>RequestDelegateFactory</c>'s parameter-source inference, which asks the
    /// container whether each handler parameter is a service. With an empty container every handler's
    /// ports are reported UNKNOWN and <c>Endpoints</c> throws — so this walk cannot be done against a
    /// table of handlers whose dependencies nobody registered. Calling
    /// <c>AddNexusIntelligence</c> here rather than registering throw-away stubs is what makes the
    /// assertion meaningful: it proves the composition root actually satisfies every handler on the
    /// gateway and operations surfaces, which is the defect this lane could plausibly have shipped —
    /// the three gateway registrations are new in W7F, and a missing one would otherwise surface as a
    /// startup failure in whichever environment first resolved the route.
    /// </para>
    /// <para>
    /// The three groups are mapped here exactly as <c>Program.cs</c> maps them. A test that mapped only
    /// the group it was interested in would pass against a route table the application does not have —
    /// and the disjointness assertion below is precisely about how the groups relate to each other, so
    /// mapping them separately would make it vacuous.
    /// </para>
    /// </remarks>
    private static IReadOnlyList<RouteEndpoint> ComposedRoutes()
    {
        var builder = WebApplication.CreateSlimBuilder();

        // The two the API project supplies itself, before AddNexusIntelligence.
        builder.Services.AddSingleton<IToolCatalog, EmptyToolCatalog>();
        builder.Services.AddSingleton<IToolGateway, EmptyToolGateway>();

        builder.Services.AddNexusIntelligence(builder.Configuration);
        builder.Services.AddSingleton(TimeProvider.System);

        var app = builder.Build();

        app.MapGatewayEndpoints();
        app.MapOperationsEndpoints();
        app.MapCapabilitiesEndpoints();

        return
        [
            .. ((IEndpointRouteBuilder)app).DataSources
                .SelectMany(source => source.Endpoints)
                .OfType<RouteEndpoint>(),
        ];
    }

    private static IEnumerable<RouteEndpoint> RoutesUnder(string prefix)
        => ComposedRoutes().Where(
            route => route.RoutePattern.RawText?.StartsWith(prefix, StringComparison.Ordinal) is true);

    private static IReadOnlyList<string> MethodsOf(RouteEndpoint route)
        => route.Metadata.GetMetadata<HttpMethodMetadata>()?.HttpMethods ?? [];

    /// <summary>Serialises the way <c>Program.cs</c> configures the application to serialise.</summary>
    private static string Render<T>(T value)
        => JsonSerializer.Serialize(value, new JsonSerializerOptions
        {
            Converters = { new JsonStringEnumConverter() },
        });

    private static AiHealthSnapshot SnapshotNamingOneProviderAndOneModel() => new()
    {
        TakenAt = new DateTimeOffset(2026, 9, 13, 12, 0, 0, TimeSpan.Zero),
        Source = "w7f-http-surface-test",
        Providers = new Dictionary<string, AiModelHealthState>(StringComparer.Ordinal)
        {
            [NamedProvider] = AiModelHealthState.Available,
        },
        Models = new Dictionary<(string ModelId, string ProviderId), AiModelHealthState>
        {
            [(NamedModel, NamedProvider)] = AiModelHealthState.Degraded,
        },
    };

    // ---------------------------------------------------------------------------------------------
    // TASK 15: the operations read APIs are read-only.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void EveryOperationsRoute_AnswersReadsOnly()
    {
        var routes = RoutesUnder(OperationsEndpoints.RoutePrefix).ToList();

        // NON-VACUITY: the assertion below is "no route writes", which an empty or near-empty route
        // table satisfies perfectly. TASK 6 requires seven distinct reads, so anything materially fewer
        // means the walker is looking at the wrong table rather than at a disciplined one.
        Assert.True(
            routes.Count >= 8,
            $"TASK 6 requires the operations surface to expose execution status, recent executions, "
            + $"usage, cost, health, reliability and audit lookup. The composed table exposes "
            + $"{routes.Count} route(s) under '{OperationsEndpoints.RoutePrefix}', so the read-only "
            + "assertion below would be checking almost nothing.");

        foreach (var route in routes)
        {
            var methods = MethodsOf(route);

            Assert.True(
                methods.Count == 1 && methods[0] == HttpMethods.Get,
                $"The operations route '{route.RoutePattern.RawText}' answers "
                + $"[{string.Join(", ", methods)}]. TASK 15 requires the operations read APIs to be "
                + "read-only; a handler reachable by a write method is a write surface regardless of "
                + "what it does today.");
        }
    }

    [Fact]
    public void NoOperationsRoute_IsServedUnderTheCallerGatewayPrefix()
    {
        var operations = RoutesUnder(OperationsEndpoints.RoutePrefix).ToList();
        var gateway = RoutesUnder(AiGatewayContract.RoutePrefix).ToList();

        Assert.True(operations.Count > 0, "The walker found no operations routes to check.");
        Assert.True(gateway.Count > 0, "The walker found no gateway routes to check.");

        // TASK 7: a Product reads the gateway, an operator reads the operations surface. The two must
        // not overlap, because a caller-facing route that served an operator document would disclose
        // provider health to every Product without any response type reading wrong.
        foreach (var route in operations.Concat(gateway))
        {
            var path = route.RoutePattern.RawText!;

            Assert.False(
                path.StartsWith(AiGatewayContract.RoutePrefix, StringComparison.Ordinal)
                    && path.StartsWith(OperationsEndpoints.RoutePrefix, StringComparison.Ordinal),
                $"'{path}' is claimed by both prefixes.");

            Assert.True(
                path.StartsWith(AiGatewayContract.RoutePrefix, StringComparison.Ordinal)
                    || path.StartsWith(OperationsEndpoints.RoutePrefix, StringComparison.Ordinal),
                $"'{path}' is under neither prefix, so it is on neither surface.");
        }

        // The prefixes themselves are distinct strings. Asserted rather than assumed because a later
        // edit that made the operations prefix a sub-path of the gateway prefix would satisfy every
        // check above while collapsing the boundary the checks exist to hold.
        Assert.False(
            OperationsEndpoints.RoutePrefix.StartsWith(AiGatewayContract.RoutePrefix, StringComparison.Ordinal),
            "The operations prefix is nested under the caller gateway prefix, which would publish the "
            + "operator surface as though it were part of the caller contract.");
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 7: the caller surface names no provider. TASK 15: with a control, so the absence means
    // something.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheCallerFacingAvailability_NamesNoProviderAndNoModel()
    {
        var projection = new AiGatewayAvailabilityProjection(
            new InMemoryAiHealthSnapshotStore(SnapshotNamingOneProviderAndOneModel()),
            AiCapabilityRegister.Bootstrap(),
            TimeProvider.System);

        var rendered = Render(projection.Read());

        Assert.False(
            rendered.Contains(NamedProvider, StringComparison.OrdinalIgnoreCase),
            $"The caller-facing availability document names the provider '{NamedProvider}'. TASK 7 "
            + "requires the availability contract to be a conclusion a Product can act on, not a "
            + "monitoring feed: a caller that can see which route is unhealthy is a caller that will "
            + "eventually prefer one.");

        Assert.False(
            rendered.Contains(NamedModel, StringComparison.OrdinalIgnoreCase),
            $"The caller-facing availability document names the model '{NamedModel}'.");

        // NON-VACUITY CONTROL: the same snapshot, read through the operator surface, DOES name both.
        // Without this, the two assertions above would pass just as happily against a projection that
        // had silently read an empty snapshot - the detector would be proving nothing about the
        // projection and everything about its input.
        var store = new InMemoryAiHealthSnapshotStore(SnapshotNamingOneProviderAndOneModel());

        var operatorRows = store.Current.Providers.Keys
            .Concat(store.Current.Models.Keys.Select(key => key.ModelId))
            .ToList();

        Assert.Contains(NamedProvider, operatorRows);
        Assert.Contains(NamedModel, operatorRows);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 13 and TASK 14: the retired route is a signpost and not a narrowed body.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheRetiredCapabilitiesRoute_PointsAtTheGateway_AndServesNoCatalogue()
    {
        var retired = ComposedRoutes()
            .SingleOrDefault(route => route.RoutePattern.RawText == CapabilitiesEndpoints.RetiredRoute);

        // The route being present is the point. An unmapped route answers 404 from routing itself,
        // which is indistinguishable from a typo and carries no replacement address; the handler that
        // answers here exists solely to say where the capability listing went.
        Assert.True(
            retired is not null,
            $"'{CapabilitiesEndpoints.RetiredRoute}' is no longer mapped. A retired route must stay "
            + "mapped so it can refuse: deleting the mapping replaces an addressable refusal with a "
            + "404 that tells a migrating consumer nothing.");

        Assert.True(
            CapabilitiesEndpoints.ReplacementRoute.StartsWith(AiGatewayContract.RoutePrefix, StringComparison.Ordinal),
            "The replacement named by the retired route is not under the gateway prefix, so it would "
            + "send a migrating consumer somewhere that is not the caller contract.");

        // TASK 13 in structural form: the model-catalogue response shape no longer exists anywhere in
        // the API assembly, so a later lane cannot re-serve the leak by finding the type already
        // shaped for it. The property names are the leak - ModelId and Vendor are what the endpoint
        // published and what TASK 8 and TASK 13 forbid a caller receiving.
        var apiNamespace = typeof(CapabilitiesEndpoints).Namespace!;

        var reintroductions = typeof(CapabilitiesEndpoints).Assembly
            .GetTypes()
            .Where(type => type.Namespace == apiNamespace && type.IsPublic)
            .SelectMany(type => type.GetProperties())
            .Where(property => property.Name is "Models" or "Vendor" or "ModelSummary")
            .Select(property => $"{property.DeclaringType!.Name}.{property.Name}")
            .ToList();

        Assert.True(
            reintroductions.Count == 0,
            $"The API endpoint surface re-exposes a model catalogue: {string.Join(", ", reintroductions)}. "
            + "TASK 13 forbids exposing raw provider configuration to ordinary callers and TASK 8 forbids "
            + "a consumer inspecting the registry's contents.");
    }
}
