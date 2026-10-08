using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Nexus.Intelligence.Api;
using Nexus.Intelligence.Api.DependencyInjection;
using Nexus.Intelligence.Api.Endpoints;
using Nexus.Intelligence.Api.Tooling;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Registry;
using Nexus.Platform.Contracts.Secrets;
using Nexus.Platform.Contracts.Tools;
using Nexus.Platform.Core.Secrets;
using Nexus.Platform.Providers.OpenAI;

namespace Nexus.Intelligence.LiveSmokeHost;

/// <summary>
/// The AI Head's estate, composed through its own composition root, with a <b>real</b> provider at
/// the end of it.
/// </summary>
/// <remarks>
/// <para>
/// <b>Nothing is faked.</b> This is the difference between this suite and
/// <c>W7f2HttpEndToEndTests</c>, and stating it precisely matters because the two look alike. That
/// suite replaces exactly one thing — <c>IModelStep</c>, "the seam that leaves the process" — with
/// a recording fake, and correctly so: it tests the governed path, and the governed path is
/// everything on this side of the seam. This suite tests the other half. It replaces nothing, so
/// the real <c>ModelStep</c> resolves the real routing gateway, which reaches the real
/// <c>OpenAIModelGateway</c>, which makes a real HTTPS call to OpenAI. The seam that was faked
/// there is the subject here.
/// </para>
/// <para>
/// <b>Everything else is identical, and that is the point.</b> Same composition root
/// (<c>AddNexusIntelligence</c>), same governance, same registry, same router, same operations
/// plane, same HTTP route and the same request envelope the W7F.2 suite posts. So an assertion made
/// here is about the estate a product would actually call.
/// </para>
/// <para>
/// <b>No credential is handled by this class.</b> The registry declares the secret REFERENCE
/// <see cref="LiveProviderKey.ReferenceName"/>; the value is resolved inside the provider adapter,
/// through the estate's own neutral <c>ISecretResolver</c>, which this composition binds to
/// <c>EnvironmentSecretResolver</c> — the resolver whose namespace is the process environment. The
/// value never reaches this file, the test, or any assertion message.
/// </para>
/// </remarks>
public sealed class LiveEstate : IAsyncDisposable
{
    /// <summary>The provider id this suite's registry declares. Names the estate's route, not a vendor.</summary>
    public const string ProviderId = "openai";

    /// <summary>
    /// The estate's model id, including its vendor prefix. <c>OpenAIModelGateway</c> strips the
    /// prefix before calling the vendor, so this identifier is the estate's own name for the model
    /// and <c>gpt-4.1-mini</c> is what the vendor is told. Declared once, here, so the registry and
    /// the assertions cannot disagree about which model ran.
    /// </summary>
    public const string ModelId = "openai:gpt-4.1-mini";

    private WebApplication _app = null!;

    public required HttpClient Client { get; init; }

    /// <summary>Boots the estate through the API's own composition root.</summary>
    public static async Task<LiveEstate> StartAsync()
    {
        if (!LiveProviderKey.Available())
        {
            throw new InvalidOperationException(
                "LiveEstate.StartAsync was called with no credential present. " + LiveProviderKey.SkipReason);
        }

        var builder = WebApplication.CreateSlimBuilder();

        builder.WebHost.UseUrls("http://127.0.0.1:0");

        // The configuration sources are cleared and one document supplied, for the reason W7F.2
        // records at length: `CreateSlimBuilder` would otherwise load the API project's own
        // appsettings.json from the content root, and arrays merge BY INDEX rather than replacing.
        // This suite would then be routing over models it never declared while appearing to read
        // only its own configuration. Nothing is inherited and nothing is ambient.
        //
        // The document is built by BuildConfiguration() and added, rather than streamed here, so that
        // the credential-free composition test binds byte-for-byte the configuration this method
        // boots on. Two call sites building "the same" document two ways is the divergence this
        // estate already has a type devoted to preventing (AiJsonConfiguration), and there is no
        // reason to reintroduce it here.
        builder.Configuration.Sources.Clear();
        builder.Configuration.AddConfiguration(BuildConfiguration());

        // The two ports the API project supplies in Program.cs, in the same order. They are empty
        // implementations because this suite exercises a chat capability, which uses no tool.
        builder.Services.AddSingleton<IToolCatalog, EmptyToolCatalog>();
        builder.Services.AddSingleton<IToolGateway, EmptyToolGateway>();

        // The credential boundary, bound exactly as a host binds it: the neutral contract in
        // Platform, the implementation chosen here. The environment resolver opens no credential
        // store, so this composition has no custody of any secret file.
        builder.Services.AddSingleton<ISecretResolver, EnvironmentSecretResolver>();

        // The real adapter, registered before the composition root, as Program.cs does.
        builder.Services.AddOpenAIModelProvider(builder.Configuration.GetSection("Platform:Providers"));

        builder.Services.AddNexusIntelligence(builder.Configuration);

        builder.Services.AddSingleton(TimeProvider.System);
        builder.Services.AddProblemDetails();
        builder.Services.ConfigureHttpJsonOptions(http => AiJsonConfiguration.Apply(http.SerializerOptions));

        // NOTE WHAT IS ABSENT: there is no `AddSingleton<IModelStep>` substitution here. The real
        // ModelStep from the composition root serves these requests, which is the whole difference
        // between this suite and the W7F.2 one.

        var app = builder.Build();
        app.MapGatewayEndpoints();
        await app.StartAsync();

        return new LiveEstate
        {
            _app = app,
            Client = new HttpClient { BaseAddress = new Uri(app.Urls.First()) },
        };
    }

    /// <summary>Runs one real turn over HTTP and returns what the caller was given.</summary>
    public async Task<AiCapabilityResponse> ChatAsync(string prompt, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"{AiGatewayContract.RoutePrefix}/invoke")
        {
            Content = new StringContent(RequestBody(prompt), Encoding.UTF8, "application/json"),
        };

        request.Headers.TryAddWithoutValidation(AiGatewayContract.VersionHeader, AiGatewayContract.Version);

        using var response = await Client.SendAsync(request, ct);
        var body = await response.Content.ReadAsStringAsync(ct);

        if (response.StatusCode != HttpStatusCode.OK)
        {
            throw new InvalidOperationException(
                $"the live turn was refused at the transport: {(int)response.StatusCode} {response.StatusCode}. Body: {body}");
        }

        return JsonSerializer.Deserialize<AiCapabilityResponse>(body, WireJson)
            ?? throw new InvalidOperationException($"the live turn returned a body that would not bind: {body}");
    }

    /// <summary>
    /// The same JSON configuration the server writes responses with, reached through the server's own
    /// type rather than restated here.
    /// </summary>
    /// <remarks>
    /// <see cref="AiJsonConfiguration"/> exists precisely so a client and a server cannot configure
    /// JSON differently — the divergence it was written to prevent is real and shipped once. Calling
    /// <c>Apply</c> is the whole of the contract; a private copy of the enum converter here would
    /// reintroduce the drift that type was created to remove.
    /// </remarks>
    private static JsonSerializerOptions WireJson { get; } = CreateWireJson();

    private static JsonSerializerOptions CreateWireJson()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        AiJsonConfiguration.Apply(options);
        return options;
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        Client.Dispose();
        await _app.DisposeAsync();
    }

    /// <summary>
    /// A well-formed capability request, the same envelope the W7F.2 HTTP suite posts.
    /// </summary>
    /// <remarks>
    /// Reusing that envelope deliberately: it is the shape already proven to cross this gateway, so
    /// a failure here is about the provider and not about the request. <c>execution.costCurrency</c>
    /// and <c>execution.quality</c> are both stated for the reasons that suite records — a currency
    /// that nobody stated is not a wildcard to the cost gate, and the contract makes an execution
    /// policy without a quality requirement a deserialisation failure.
    /// </remarks>
    private static string RequestBody(string prompt) =>
        $$"""
        {
          "requestId": "req-live-{{Guid.NewGuid():N}}",
          "capability": "chat.complete",
          "purpose": "live provider smoke",
          "requester": {
            "head": "Platform",
            "productId": "intelligence",
            "principalId": "live-smoke",
            "isServicePrincipal": true
          },
          "execution": { "costCurrency": "USD", "quality": {} },
          "input": { "kind": "UserMessage", "text": {{JsonSerializer.Serialize(prompt)}}, "attachments": [] },
          "classification": "Internal",
          "correlationId": "correlation-live-smoke",
          "idempotencyKey": "idem-live-{{Guid.NewGuid():N}}"
        }
        """;

    /// <summary>
    /// The registry the router reads, exposed so it can be validated WITHOUT a credential.
    /// </summary>
    /// <remarks>
    /// <para>
    /// This exists for one reason: the live tests cannot run on a machine with no key, and a fixture
    /// whose configuration is never parsed is a fixture whose first real run is also its first test.
    /// <c>LiveEstateCompositionTests</c> builds this through the estate's own
    /// <c>ConfiguredAiRegistry</c> and asserts it parses, approves and reports healthy — none of
    /// which needs a key, a network call or a credential of any kind. That converts "unexecuted"
    /// into "unexecuted but configuration-validated", a materially weaker claim than a live pass and
    /// a materially stronger one than nothing.
    /// </para>
    /// <para>
    /// <b>One provider, one model, both approved, both healthy, both UNPRICED.</b> Approval is
    /// stated because the estate is fail-closed: the committed configuration declares none, so an
    /// approval-free fixture would be refused by governance before any provider was reached — a
    /// green-looking suite that never called a model. <c>PermitsRemoteEgress</c> is <c>true</c> here
    /// and nowhere else in the estate's tests, because this is the one suite whose purpose is to
    /// leave the machine.
    /// </para>
    /// <para>
    /// <b>Unpriced is a decision, not an omission.</b> The estate ships two closed cost gates: the
    /// governance evaluator refuses a priced execution with no covering budget rule, and the
    /// operational plane refuses an uncovered priced execution. A smoke test has no basis for
    /// stating a spending ceiling — inventing one would be exactly the arbitrary production
    /// threshold this estate forbids, and a ceiling chosen to be unreachable would be an allowance
    /// rather than a control. An unpriced route is admitted by the budget policy's
    /// <c>OnUnpricedExecution</c>, which is the contract's own permissive default, so no ceiling has
    /// to be invented. Cost is therefore asserted nowhere in this suite; token counts are, because
    /// those are real observations.
    /// </para>
    /// </remarks>
    public static AiRegistryConfiguration RegistryConfiguration() => new()
    {
        Provenance = "Nexus.Intelligence.LiveSmokeHost - the provider-specific AI Head smoke fixture.",
        Routing = new AiRoutingConfigurationEntry { Objective = "Balanced", FallbackDepth = 0 },
        Providers =
        [
            new AiProviderConfigurationEntry
            {
                ProviderId = ProviderId,
                DisplayName = "OpenAI",
                AdapterIdentity = "Nexus.Platform.Providers.OpenAI.OpenAIModelGateway",
                Capabilities = [AiCapabilities.ChatComplete],
                Enabled = true,
                SecretReference = LiveProviderKey.ReferenceName,
                PermitsRemoteEgress = true,
                Trust = "Approved",
                Priority = 10,
                Weight = 1.0,
                Approval = "Approved",
                MaxClassification = "Secret",
                ApprovedBy = "w7g2-live-smoke-owner",
                GovernanceRationale = "Live provider smoke fixture; the one estate whose purpose is to call a vendor.",
            },
        ],
        Models =
        [
            new AiModelConfigurationEntry
            {
                ModelId = ModelId,
                ProviderId = ProviderId,
                DisplayName = ModelId,
                Capabilities = [AiCapabilities.ChatComplete],
                MaxContextTokens = 128_000,
                MaxOutputTokens = 4_096,
                InputModalities = ["Text"],
                OutputModalities = ["Text"],
                Reasoning = "High",
                RelativeSpeed = "Normal",
                Availability = "Available",
                Enabled = true,
                // No cost members: see the unpriced note above.
                Approval = "Approved",
                MaxClassification = "Secret",
                ApprovedBy = "w7g2-live-smoke-owner",
                GovernanceRationale = "Live provider smoke fixture.",
            },
        ],
        Health =
        [
            new AiHealthConfigurationEntry { ProviderId = ProviderId, ModelId = null, State = "Available" },
            new AiHealthConfigurationEntry { ProviderId = ProviderId, ModelId = ModelId, State = "Available" },
        ],
    };

    /// <summary>
    /// The configuration <see cref="StartAsync"/> boots on, built the way a host builds it and
    /// <b>with no credential required and nothing resolved</b>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Separated from <see cref="StartAsync"/> so that <c>LiveEstateCompositionTests</c> can bind and
    /// validate <i>this exact document</i> — the same bytes, the same binder, the same registry type —
    /// on a machine with no key. Without it, the only artefact that could be checked would be
    /// <see cref="RegistryConfiguration"/>, a C# object literal that a reader has to trust matches
    /// what the JSON says; with it, the check is on what the estate actually reads.
    /// </para>
    /// <para>
    /// <b>It proves configuration, never connectivity.</b> A green result here says the document
    /// parses, the entries are approved, and the health source answers — it says nothing about whether
    /// a vendor is reachable, and the live suite is the only thing that can say that. The distinction
    /// is the whole reason both exist.
    /// </para>
    /// </remarks>
    public static IConfigurationRoot BuildConfiguration() =>
        new ConfigurationBuilder()
            .AddJsonStream(new MemoryStream(Encoding.UTF8.GetBytes(EstateJson())))
            .Build();

    /// <summary>The whole configuration document the estate is composed from.</summary>
    private static string EstateJson()
    {
        var root = new Dictionary<string, object?>
        {
            ["Ai"] = new Dictionary<string, object?>
            {
                [AiRegistryConfiguration.SectionName.Split(':')[1]] = RegistryConfiguration(),

                // The operational budget plane is composed and told, explicitly, that an uncovered
                // PRICED execution is refused. Stated rather than omitted, because omitting it would
                // reach Refuse by default and this fixture is meant to be read, not inferred.
                //
                // There is deliberately NO `OnUnpricedExecution` line here. It reads like a control
                // and is not one: AiOperationsConfiguration.BudgetPolicy() does not bind that member
                // at all — it is the contract's own default (AiOperationsBudgetPolicy.Default
                // .OnUnpricedExecution, which is Allow) and no configuration key can change it. A
                // line asserting it would be inert while appearing to decide the thing this fixture
                // depends on, which is the exact failure mode this estate's doctrine is written
                // against. What the live suite relies on is therefore asserted where it can actually
                // fail: LiveEstateCompositionTests pins the parsed policy's OnUnpricedExecution, so a
                // future change to that default breaks a fast keyless test instead of surfacing as an
                // unexplained refusal on a paid run.
                ["Operations"] = new Dictionary<string, object?>
                {
                    ["Budget"] = new Dictionary<string, object?>
                    {
                        ["Available"] = true,
                        ["OnUncoveredPricedExecution"] = "Refuse",
                        ["Rules"] = Array.Empty<object>(),
                    },
                },
            },

            // Bound by AddOpenAIModelProvider against the Platform:Providers section. The catalog
            // is what the estate's model catalog reports; the router reads Ai:Registry. Both are
            // declared so the two views of "which models exist" name the same one.
            ["Platform"] = new Dictionary<string, object?>
            {
                ["Providers"] = new Dictionary<string, object?>
                {
                    ["OpenAI"] = new Dictionary<string, object?>
                    {
                        // A REFERENCE, never a value. Resolved at the point of use by the adapter.
                        ["ApiKeyRef"] = LiveProviderKey.ReferenceName,
                        ["Catalog"] = new Dictionary<string, object?>
                        {
                            ["Provenance"] = "Nexus.Intelligence.LiveSmokeHost.",
                            ["Models"] = new object[]
                            {
                                new Dictionary<string, object?>
                                {
                                    ["ModelId"] = ModelId,
                                    ["Vendor"] = "openai",
                                    ["Capabilities"] = new[] { "ChatComplete" },
                                    ["ContextWindow"] = 128_000,
                                    ["CostPer1kIn"] = 0m,
                                    ["CostPer1kOut"] = 0m,
                                    ["Latency"] = "Normal",
                                },
                            },
                        },
                    },
                },
            },
        };

        return JsonSerializer.Serialize(root, new JsonSerializerOptions
        {
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        });
    }
}
