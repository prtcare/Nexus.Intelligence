using Microsoft.OpenApi;
using Nexus.Intelligence.Api;
using Nexus.Intelligence.Api.DependencyInjection;
using Nexus.Intelligence.Api.Endpoints;
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

app.Run();
