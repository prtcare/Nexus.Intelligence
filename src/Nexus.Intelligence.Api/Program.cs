using Microsoft.AspNetCore.Routing;
using Microsoft.OpenApi;
using Nexus.Intelligence.Api;
using Nexus.Intelligence.Api.DependencyInjection;
using Nexus.Intelligence.Api.Endpoints;
using Nexus.Intelligence.Api.Operations;
using Nexus.Intelligence.Api.ResultReports;
using Nexus.Intelligence.Api.Tooling;
using Nexus.Platform.Contracts.Tools;
using Nexus.Platform.Core;
using Nexus.Platform.Providers.OpenAI;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddNexusPlatform(builder.Configuration);
builder.Services.AddOpenAIModelProvider(builder.Configuration.GetSection("Platform:Providers"));

// Nexus.Platform.Tools has no governed tool registry yet (see Nexus.Platform.Tools/ToolProvider.cs).
builder.Services.AddSingleton<IToolCatalog, EmptyToolCatalog>();
builder.Services.AddSingleton<IToolGateway, EmptyToolGateway>();

builder.Services.AddNexusIntelligence(builder.Configuration);
builder.Services.AddSingleton<IResultReportStore, InMemoryResultReportStore>();

builder.Services.AddSingleton(TimeProvider.System);

builder.Services.ConfigureHttpJsonOptions(options => AiJsonConfiguration.Apply(options.SerializerOptions));

builder.Services.AddProblemDetails();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(options =>
{
    options.SwaggerDoc(
        "v1",
        new OpenApiInfo
        {
            Title = "Nexus Intelligence API v1",
            Version = "v1"
        });
});

var app = builder.Build();

app.UseSwagger();
app.UseSwaggerUI(options =>
{
    options.SwaggerEndpoint("/swagger/v1/swagger.json", "Nexus Intelligence API v1");
    options.RoutePrefix = "swagger";
});

app.UseHttpsRedirection();

app.MapHealthEndpoints();
app.MapTurnsEndpoints();
app.MapResultsEndpoints();
app.MapPlansEndpoints();
// W7F: the caller-facing gateway, then the operator-facing read surface. Mapped in that order so that
// the route table reads the way the boundary is meant to be understood, and both after the legacy turn
// surface they sit beside rather than replace.
app.MapGatewayEndpoints();
app.MapOperationsEndpoints();

// Retained, and mapped LAST on purpose: this route now answers 410 Gone with the gateway's replacement
// address, so it is a signpost rather than a surface. See CapabilitiesEndpoints.
app.MapCapabilitiesEndpoints();

// W10.7: the publication mode, and it is checked AFTER the route table is built and BEFORE the host
// listens. Both halves of that placement are load-bearing. After, because the published API inventory
// is read from the built EndpointDataSource and a document projected before mapping would report the
// estate's surfaces as empty. Before, because a publication must never be the reason an estate started
// serving: this mode writes one file and exits without opening a socket.
//
// It runs in the host's own process rather than in a separate tool for the reason the directive gives:
// a publisher that composed its own container would be a second composition root, and could publish an
// estate the host does not run.
if (AiOperationsPublicationCli.IsInvocation(args))
{
    // The route table is read from the route builder's own data sources rather than from the container.
    // The container's EndpointDataSource is a composite the routing middleware populates on the first
    // request, and this mode never serves one — resolving it here yields an empty table, which would
    // publish an estate with no APIs at all. This is the same data source the middleware would have
    // consumed, read before anything asks it to serve.
    var routeBuilder = (IEndpointRouteBuilder)app;

    return await AiOperationsPublicationCli.RunAsync(
        builder.Services,
        app.Services,
        app.Configuration,
        new CompositeEndpointDataSource(routeBuilder.DataSources),
        args,
        Console.Out);
}

app.Run();

return 0;
