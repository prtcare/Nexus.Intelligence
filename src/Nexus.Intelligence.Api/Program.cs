using System.Text.Json.Serialization;
using Microsoft.OpenApi;
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

builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.Converters.Add(new JsonStringEnumConverter());
});

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
app.MapCapabilitiesEndpoints();

app.Run();
