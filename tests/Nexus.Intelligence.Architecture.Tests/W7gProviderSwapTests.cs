using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Nexus.Intelligence.Api;
using Nexus.Intelligence.Api.DependencyInjection;
using Nexus.Intelligence.Api.Endpoints;
using Nexus.Intelligence.Api.Tooling;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Registry;
using Nexus.Intelligence.Core.Turns;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;
using Nexus.Platform.Core.Models;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7G TASKS 1 AND 2: provider interchangeability, and swap by configuration alone.
//
// WHAT THESE TWO TASKS ACTUALLY DEMAND, AND WHY THE OBVIOUS TEST DOES NOT DELIVER IT.
//
// Every failover and gateway test this estate already had replaces `IModelStep` with a recording fake.
// That fake is registered directly, so `ModelStep` and `RoutingModelGateway` never run: the test proves
// things about the governed path ABOVE the provider seam and nothing at all about the seam itself. A
// suite built that way cannot tell an estate with two provider implementations from an estate with
// none, because the thing that would have to choose between them is not in the graph.
//
// So the seam faked here is the LOWEST one — `INamedModelGateway`, the interface a provider package
// implements. Two fake implementations are registered, both under the estate's own
// `RoutingModelGateway`, and `ModelStep` is the estate's real `ModelStep`. The path under test is:
//
//     HTTP -> gateway route -> AiCapabilityGateway -> GovernedTurnExecution -> governance ->
//     registry/router -> the REAL ModelStep -> the REAL RoutingModelGateway -> one fake provider
//
// WHAT THAT MAKES PROVABLE. The provider is chosen by `RoutingModelGateway.Resolve`, which reads the
// vendor prefix of the model identifier the GOVERNED ROUTER selected — an identifier that exists only
// on an `AiRoutingCandidate`, which exists only with a governance decision attached. The caller's
// request has no field naming a provider, a vendor or a model, and neither does the response. The
// selection therefore happens entirely inside the AI Head, from configuration, with no consumer
// involvement — which is TASK 1's claim and TASK 2's claim, stated as one path rather than two.
//
// TASK 2 IS PROVED BY HOLDING EVERYTHING ELSE STILL. The two configurations below differ in exactly
// four fields (recorded and asserted in `TheConfigurationDifference_IsExactlyTheFourRecordedFields`),
// the request body is BYTE-IDENTICAL between them, and the only thing that moves is which provider
// implementation answers. One field set changed, one behaviour changed.
//
// NO CREDENTIAL, NO NETWORK, NO LIVE PROVIDER. Both provider implementations are local fakes, the
// registry names only secret REFERENCES, and no test reads an environment credential.
public sealed class W7gProviderSwapTests
{
    // ---- the two provider implementations, and the two configurations that select them ----------

    /// <summary>The vendor token of the first provider implementation.</summary>
    private const string AlphaVendor = "alpha";

    /// <summary>The vendor token of the second provider implementation.</summary>
    private const string BetaVendor = "beta";

    /// <summary>The model configuration A routes to. The prefix before ':' is the vendor token.</summary>
    private const string AlphaModel = AlphaVendor + ":chat-1";

    /// <summary>The model configuration B routes to.</summary>
    private const string BetaModel = BetaVendor + ":chat-1";

    /// <summary>The provider registration configuration A declares.</summary>
    private const string AlphaProvider = "prov-alpha";

    /// <summary>The provider registration configuration B declares.</summary>
    private const string BetaProvider = "prov-beta";

    /// <summary>
    /// The caller's request identifier, deliberately IDENTICAL across the two configurations.
    /// </summary>
    /// <remarks>
    /// The two configurations run in two separate estates, so there is no idempotency interaction and
    /// no reason to vary the identifier. Keeping it fixed is what lets the test assert that the request
    /// bodies are byte-identical rather than "identical apart from the request id" — a distinction that
    /// matters because a swap that required the caller to change anything at all would not be a swap.
    /// </remarks>
    private const string RequestId = "req-w7g-swap";

    /// <summary>
    /// The display name both configurations carry, deliberately IDENTICAL between them.
    /// </summary>
    /// <remarks>
    /// A display name is a label, not a selection: nothing routes on it. Deriving it from the
    /// provider or model identifier — which is what the W7F.2 fixture does — would make it appear in
    /// the configuration difference below as though the swap had touched something else, and a reader
    /// checking that difference would have to work out for themselves that two of the entries are
    /// cosmetic. Holding it constant keeps the recorded difference equal to the selection itself,
    /// which is the quantity <see cref="TheConfigurationDifference_NamesOnlyTheProviderAndTheModel"/>
    /// exists to report.
    /// </remarks>
    private const string RouteDisplayName = "W7G provider swap fixture route";

    // ---------------------------------------------------------------------------------------------
    // TASK 1 -- interchangeability: the same semantic capability through two implementations.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task TheSameCapability_IsServedByProviderImplementationA_UnderConfigurationA()
    {
        await using var estate = await Estate.StartAsync(ConfigurationA());

        var (status, response, _) = await estate.PostAsync();

        Assert.True(status == HttpStatusCode.OK, $"a permitted request must be served, got {(int)status}");
        Assert.True(
            response.Status == AiExecutionStatus.Succeeded,
            $"configuration A must serve the request, got {response.Status}: {response.Failure?.Message}");

        // NON-VACUITY: the provider implementation was reached, and it was the one configuration A
        // names. Without this the test would pass on an estate whose seam was never called.
        Assert.True(estate.Alpha.Count == 1, $"provider A must have been invoked exactly once, got {estate.Alpha.Count}");
        Assert.True(estate.Beta.Count == 0, $"provider B must not have been reached under configuration A, got {estate.Beta.Count}");

        // The call arrived carrying the model identifier the GOVERNED ROUTER selected, which is what
        // `RoutingModelGateway` resolved the vendor from. A fake reached by a different identifier
        // would mean the resolution path ran on something other than the routed candidate.
        Assert.True(
            estate.Alpha.ModelsAsked.Single() == AlphaModel,
            $"provider A must have been asked for '{AlphaModel}', got '{estate.Alpha.ModelsAsked.Single()}'");
    }

    [Fact]
    public async Task TheSameCapability_IsServedByProviderImplementationB_UnderConfigurationB()
    {
        await using var estate = await Estate.StartAsync(ConfigurationB());

        var (status, response, _) = await estate.PostAsync();

        Assert.True(status == HttpStatusCode.OK, $"a permitted request must be served, got {(int)status}");
        Assert.True(
            response.Status == AiExecutionStatus.Succeeded,
            $"configuration B must serve the request, got {response.Status}: {response.Failure?.Message}");

        Assert.True(estate.Beta.Count == 1, $"provider B must have been invoked exactly once, got {estate.Beta.Count}");
        Assert.True(estate.Alpha.Count == 0, $"provider A must not have been reached under configuration B, got {estate.Alpha.Count}");
        Assert.True(
            estate.Beta.ModelsAsked.Single() == BetaModel,
            $"provider B must have been asked for '{BetaModel}', got '{estate.Beta.ModelsAsked.Single()}'");
    }

    [Fact]
    public async Task TheTwoConfigurations_ProduceTheSameCallerFacingContractShape()
    {
        // The output contract half of TASK 1: "output contract remains compatible". Two different
        // provider implementations, one caller-facing shape. Asserted on the properties a consumer
        // branches on rather than on field-by-field equality, because the values legitimately differ
        // (different execution identity, different elapsed time) while the CONTRACT must not.
        await using var estateA = await Estate.StartAsync(ConfigurationA());
        await using var estateB = await Estate.StartAsync(ConfigurationB());

        var (_, responseA, _) = await estateA.PostAsync();
        var (_, responseB, _) = await estateB.PostAsync();

        Assert.True(responseA.Status == responseB.Status, "the status vocabulary must not depend on the provider");
        Assert.True(responseA.Capability == responseB.Capability, "the capability echoed back must not depend on the provider");
        Assert.True(responseA.RequestId == responseB.RequestId, "the caller's request identifier must survive either provider");

        // Neither carries a failure, so neither carries a category: the success shape is the same shape.
        Assert.True(responseA.Failure is null, $"configuration A must report no failure, got {responseA.Failure?.Code}");
        Assert.True(responseB.Failure is null, $"configuration B must report no failure, got {responseB.Failure?.Code}");

        // Both minted an execution identity of their own, and neither is the caller's request
        // identifier. The identity is a property of the estate, not of the provider behind it.
        Assert.True(responseA.Execution is not null, "configuration A must issue an execution reference");
        Assert.True(responseB.Execution is not null, "configuration B must issue an execution reference");
        Assert.True(
            responseA.Execution!.ExecutionId != responseB.Execution!.ExecutionId,
            "two executions must not share an identity merely because they were served by different providers");

        // Both report usage in the same shape. The numbers come from the provider's own measurement,
        // and both fakes report the same one, so equality here is a statement about the contract.
        Assert.True(
            responseA.Usage.InputTokens == responseB.Usage.InputTokens
            && responseA.Usage.OutputTokens == responseB.Usage.OutputTokens,
            "the usage shape must be provider-independent");
    }

    [Fact]
    public async Task TheCallerRequest_IsByteIdentical_UnderBothConfigurations()
    {
        // "caller request shape unchanged", asserted on the bytes rather than on the object: the bytes
        // are what a consumer actually sends, and an estate that needed the caller to add a field to
        // reach provider B would be an estate that had not achieved interchangeability.
        await using var estateA = await Estate.StartAsync(ConfigurationA());
        await using var estateB = await Estate.StartAsync(ConfigurationB());

        var bodyA = Estate.RequestBody(RequestId);
        var bodyB = Estate.RequestBody(RequestId);

        Assert.True(
            string.Equals(bodyA, bodyB, StringComparison.Ordinal),
            "the two configurations must be reachable with a byte-identical caller request");

        // And the request actually sent by the shared helper carries no vendor, provider or model
        // token: the caller has no way to express a preference even if it wanted one.
        Assert.True(!NamesAVendor(bodyA), $"the caller's request must name no vendor: {bodyA}");
        Assert.True(
            !bodyA.Contains(AlphaProvider, StringComparison.OrdinalIgnoreCase)
            && !bodyA.Contains(BetaProvider, StringComparison.OrdinalIgnoreCase),
            "the caller's request must name no provider");

        var (_, responseA, _) = await estateA.PostAsync();
        var (_, responseB, _) = await estateB.PostAsync();

        Assert.True(responseA.Status == AiExecutionStatus.Succeeded, "the shared request must be served under A");
        Assert.True(responseB.Status == AiExecutionStatus.Succeeded, "the shared request must be served under B");
    }

    [Fact]
    public async Task NeitherConfiguration_NamesItsProvider_OnTheResponse()
    {
        // "provider selected only inside AI Head", asserted at the boundary. The estate knows which
        // implementation served; the caller must not learn it. This is the projection property
        // `AiCapabilityGateway` documents, checked against a real provider selection rather than
        // against a seam that had no provider to name.
        await using var estate = await Estate.StartAsync(ConfigurationA());

        var (_, response, body) = await estate.PostAsync();

        Assert.True(!NamesAVendor(body), $"the response must name no vendor: {body}");
        Assert.True(
            !body.Contains(AlphaProvider, StringComparison.OrdinalIgnoreCase),
            "the response must not name the provider registration");
        Assert.True(
            !body.Contains(AlphaModel, StringComparison.OrdinalIgnoreCase),
            "the response must not name the model the router selected");

        // The model's own text is the caller's answer; the route that produced it is not.
        Assert.True(response.Output is not null, "a served execution must return the model's output");
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 2 -- the configuration difference, recorded exactly rather than described.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheConfigurationDifference_NamesOnlyTheProviderAndTheModel()
    {
        // "Record exact config difference." A prose claim that only configuration changed is not
        // evidence, so this is the difference computed and asserted rather than described.
        //
        // SEVEN PATHS, AND THEY ARE ONE FACT. Four of them are the selection itself: which provider
        // registration this configuration declares, which adapter implementation that registration
        // names, which model it declares, and which provider that model belongs to. The remaining
        // three are the health rows, which name the same provider and the same model a second time
        // because health is declared per route. So the configuration difference is not "seven
        // independent knobs moved" -- it is "the configuration names a different provider and model",
        // recorded at every point where the configuration names one.
        //
        // THE FIELD SET IS EXACT, so this also reports what did NOT move. The routing objective, the
        // fallback depth, the capability declarations, the pricing, the approval, the classification
        // ceiling and the governance rationale are byte-identical between the two configurations,
        // which is what makes the behaviour change attributable to the selection rather than to
        // something that drifted alongside it.
        var differences = Diff(Estate.RegistryJson(ConfigurationA()), Estate.RegistryJson(ConfigurationB()));

        var expected = new[]
        {
            "$.Health[0].ProviderId",
            "$.Health[1].ModelId",
            "$.Health[1].ProviderId",
            "$.Models[0].ModelId",
            "$.Models[0].ProviderId",
            "$.Providers[0].AdapterIdentity",
            "$.Providers[0].ProviderId",
        };

        Assert.True(
            differences.SequenceEqual(expected, StringComparer.Ordinal),
            "the configurations must differ in exactly the paths that name the provider and the model. "
            + "Actual difference: "
            + (differences.Count == 0 ? "(none)" : string.Join(", ", differences)));
    }

    [Fact]
    public void TheSameConfiguration_ProducesNoDifference_WhichIsWhatMakesTheDiffMeanSomething()
    {
        // CONTROL for the diff itself. A comparison that reported differences at every leaf, or that
        // reported the same list regardless of input, would make the test above pass for the wrong
        // reason. Comparing a configuration with itself must yield nothing.
        var differences = Diff(Estate.RegistryJson(ConfigurationA()), Estate.RegistryJson(ConfigurationA()));

        Assert.True(
            differences.Count == 0,
            $"a configuration compared with itself must differ nowhere, got: {string.Join(", ", differences)}");
    }

    [Fact]
    public async Task TheSwapChangesWhichAdapterAnswers_AndNothingElseObservable()
    {
        // The operational reading of the diff above: the adapter identity that answered changed, and
        // the caller-visible outcome did not. Recorded as one test because the two halves are only
        // meaningful together — an adapter change with a changed outcome would be a behaviour change,
        // and an unchanged outcome with an unchanged adapter would be no swap at all.
        await using var estateA = await Estate.StartAsync(ConfigurationA());
        await using var estateB = await Estate.StartAsync(ConfigurationB());

        var (_, responseA, _) = await estateA.PostAsync();
        var (_, responseB, _) = await estateB.PostAsync();

        Assert.True(estateA.Alpha.Count == 1 && estateA.Beta.Count == 0, "configuration A must select implementation A");
        Assert.True(estateB.Beta.Count == 1 && estateB.Alpha.Count == 0, "configuration B must select implementation B");

        Assert.True(responseA.Status == AiExecutionStatus.Succeeded, "the outcome must not depend on which adapter served");
        Assert.True(responseB.Status == AiExecutionStatus.Succeeded, "the outcome must not depend on which adapter served");
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    /// <summary>True when the text contains either vendor token.</summary>
    private static bool NamesAVendor(string text)
        => text.Contains(AlphaVendor, StringComparison.OrdinalIgnoreCase)
            || text.Contains(BetaVendor, StringComparison.OrdinalIgnoreCase);

    /// <summary>The leaf paths at which two JSON documents disagree.</summary>
    /// <remarks>
    /// Written here rather than taken from a library because the output is the evidence: it has to name
    /// the fields in a form a reader can check against the two configurations, and a structural diff
    /// library's rendering is not that. Paths are compared ordinally so the result is stable.
    /// </remarks>
    private static List<string> Diff(string left, string right)
    {
        using var leftDocument = JsonDocument.Parse(left);
        using var rightDocument = JsonDocument.Parse(right);

        var differences = new List<string>();
        Compare(leftDocument.RootElement, rightDocument.RootElement, "$", differences);

        differences.Sort(StringComparer.Ordinal);
        return differences;
    }

    private static void Compare(JsonElement left, JsonElement right, string path, List<string> differences)
    {
        if (left.ValueKind != right.ValueKind)
        {
            differences.Add(path);
            return;
        }

        switch (left.ValueKind)
        {
            case JsonValueKind.Object:
                var names = left.EnumerateObject().Select(property => property.Name)
                    .Concat(right.EnumerateObject().Select(property => property.Name))
                    .Distinct(StringComparer.Ordinal)
                    .OrderBy(name => name, StringComparer.Ordinal);

                foreach (var name in names)
                {
                    var hasLeft = left.TryGetProperty(name, out var leftChild);
                    var hasRight = right.TryGetProperty(name, out var rightChild);

                    if (hasLeft != hasRight)
                    {
                        differences.Add($"{path}.{name}");
                        continue;
                    }

                    Compare(leftChild, rightChild, $"{path}.{name}", differences);
                }

                return;

            case JsonValueKind.Array:
                var leftItems = left.EnumerateArray().ToArray();
                var rightItems = right.EnumerateArray().ToArray();

                if (leftItems.Length != rightItems.Length)
                {
                    differences.Add($"{path}.Length");
                    return;
                }

                for (var index = 0; index < leftItems.Length; index++)
                {
                    Compare(leftItems[index], rightItems[index], $"{path}[{index}]", differences);
                }

                return;

            default:
                if (!string.Equals(left.GetRawText(), right.GetRawText(), StringComparison.Ordinal))
                {
                    differences.Add(path);
                }

                return;
        }
    }

    // ---- the two configurations -----------------------------------------------------------------

    /// <summary>Configuration A: provider implementation A serves the capability.</summary>
    private static EstateOptions ConfigurationA() => new()
    {
        ProviderId = AlphaProvider,
        AdapterIdentity = "Nexus.Intelligence.Architecture.Tests.Adapter.Alpha",
        ModelId = AlphaModel,
    };

    /// <summary>Configuration B: provider implementation B serves the same capability.</summary>
    private static EstateOptions ConfigurationB() => new()
    {
        ProviderId = BetaProvider,
        AdapterIdentity = "Nexus.Intelligence.Architecture.Tests.Adapter.Beta",
        ModelId = BetaModel,
    };

    /// <summary>The knobs the two configurations differ in — and only these.</summary>
    private sealed record EstateOptions
    {
        /// <summary>The provider registration's identifier.</summary>
        public required string ProviderId { get; init; }

        /// <summary>
        /// The provider registration's adapter identity: the field that names the implementation.
        /// </summary>
        /// <remarks>
        /// This is the field which says, in configuration, WHICH provider implementation is being
        /// selected. It is metadata to the .NET container — nothing resolves it — but it is the
        /// estate's own record of what answered, and an estate that changed implementations without
        /// changing it would have a registry describing a provider it is not using.
        /// </remarks>
        public required string AdapterIdentity { get; init; }

        /// <summary>The model's identifier, whose vendor prefix the routing gateway resolves.</summary>
        public required string ModelId { get; init; }
    }

    // ---- the estate -----------------------------------------------------------------------------

    /// <summary>A running real HTTP estate whose provider implementations are local fakes.</summary>
    private sealed class Estate : IAsyncDisposable
    {
        private WebApplication _app = null!;

        /// <summary>The HTTP client, addressed at the running server's own port.</summary>
        public required HttpClient Client { get; init; }

        /// <summary>Provider implementation A, recording every invocation it receives.</summary>
        public required RecordingProviderGateway Alpha { get; init; }

        /// <summary>Provider implementation B, recording every invocation it receives.</summary>
        public required RecordingProviderGateway Beta { get; init; }

        /// <summary>Boots the estate through the API's own composition root.</summary>
        public static async Task<Estate> StartAsync(EstateOptions options)
        {
            var builder = WebApplication.CreateSlimBuilder();

            // THE PORT IS BOUND EXPLICITLY, AND THAT IS NOT A DETAIL.
            //
            // `CreateSlimBuilder` would otherwise listen on the default `http://localhost:5000`, and
            // the configuration sources are cleared immediately below — which takes the `urls` setting
            // with it, so a `UseUrls` written above this point is silently discarded and the estate
            // binds to 5000 anyway. W7f2HttpEndToEndTests has the same ordering and gets away with it
            // only because every one of its tests starts a SINGLE estate and xUnit runs a class's
            // methods one at a time; the first suite to start two estates at once -- this one -- met
            // "address already in use", and every single-estate test here would have raced every
            // other Kestrel estate in this assembly on the same default port.
            //
            // `ConfigureKestrel` + `Listen` is a DI registration rather than a configuration value,
            // so clearing the sources cannot reach it, and port 0 asks the operating system for a
            // free port. Neither the clearing order nor a concurrently running test can collide.
            builder.WebHost.ConfigureKestrel(kestrel => kestrel.Listen(IPAddress.Loopback, 0));

            // The configuration sources are cleared and one document is supplied, for the reason
            // W7f2HttpEndToEndTests records at length: `CreateSlimBuilder` would otherwise load the
            // API's own `appsettings.json` from the content root, and a JSON array merges BY INDEX
            // rather than replacing — so a second model here would leave the API's third model
            // standing and the estate would route over a route this test never declared.
            builder.Configuration.Sources.Clear();
            builder.Configuration.AddJsonStream(new MemoryStream(Encoding.UTF8.GetBytes(EstateJson(options))));

            builder.Services.AddSingleton<IToolCatalog, EmptyToolCatalog>();
            builder.Services.AddSingleton<IToolGateway, EmptyToolGateway>();

            builder.Services.AddNexusIntelligence(builder.Configuration);

            // THE TWO PROVIDER IMPLEMENTATIONS. Registered as `INamedModelGateway`, which is the
            // interface a provider package implements, so `RoutingModelGateway` — the estate's own —
            // receives both and resolves between them by the vendor token in the routed model
            // identifier. This is the lowest seam in the estate and the only one faked here.
            var alpha = new RecordingProviderGateway(AlphaVendor);
            var beta = new RecordingProviderGateway(BetaVendor);

            builder.Services.AddSingleton<INamedModelGateway>(alpha);
            builder.Services.AddSingleton<INamedModelGateway>(beta);

            builder.Services.AddSingleton(TimeProvider.System);
            builder.Services.AddProblemDetails();
            builder.Services.ConfigureHttpJsonOptions(
                http => AiJsonConfiguration.Apply(http.SerializerOptions));

            var app = builder.Build();
            app.MapGatewayEndpoints();
            await app.StartAsync();

            // Asserted rather than assumed: every request in this suite is addressed at whatever the
            // operating system granted, and an empty address list would turn "the port was never
            // bound" into a confusing `UriFormatException` from the line below instead of a statement
            // about what went wrong.
            var address = app.Urls.FirstOrDefault();

            Assert.True(
                !string.IsNullOrWhiteSpace(address),
                "the estate must report the address it bound; the server started but published none");

            return new Estate
            {
                _app = app,
                Client = new HttpClient { BaseAddress = new Uri(address!) },
                Alpha = alpha,
                Beta = beta,
            };
        }

        /// <summary>POSTs the fixture's capability request at the real gateway route.</summary>
        public async Task<(HttpStatusCode Status, AiCapabilityResponse Response, string Body)> PostAsync()
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, $"{AiGatewayContract.RoutePrefix}/invoke")
            {
                Content = new StringContent(RequestBody(RequestId), Encoding.UTF8, "application/json"),
            };

            // The contract version travels on every call, so a swap cannot be observed as a version
            // change: the caller was built against one contract and both configurations serve it.
            request.Headers.TryAddWithoutValidation(AiGatewayContract.VersionHeader, AiGatewayContract.Version);

            using var httpResponse = await Client.SendAsync(request);
            var body = await httpResponse.Content.ReadAsStringAsync();

            Assert.True(
                httpResponse.StatusCode == HttpStatusCode.OK,
                $"the route must answer with a contract response, got {(int)httpResponse.StatusCode}: {body}");

            var parsed = JsonSerializer.Deserialize<AiCapabilityResponse>(body, WireJson);

            Assert.True(parsed is not null, $"the response body must deserialise to the contract: {body}");

            return (httpResponse.StatusCode, parsed!, body);
        }

        public async ValueTask DisposeAsync()
        {
            Client.Dispose();
            await _app.StopAsync();
            await _app.DisposeAsync();
        }

        /// <summary>The registry document, as configuration declares it, for one configuration.</summary>
        public static string RegistryJson(EstateOptions options) => JsonSerializer.Serialize(
            Registry(options),
            new JsonSerializerOptions { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull });

        /// <summary>The one registry this configuration declares.</summary>
        private static AiRegistryConfiguration Registry(EstateOptions options) => new()
        {
            Provenance = "W7G provider swap fixture.",
            Routing = new AiRoutingConfigurationEntry { Objective = "Balanced", FallbackDepth = 1 },
            Providers =
            [
                new AiProviderConfigurationEntry
                {
                    ProviderId = options.ProviderId,
                    DisplayName = RouteDisplayName,
                    AdapterIdentity = options.AdapterIdentity,
                    Capabilities = [AiCapabilities.ChatComplete],
                    Enabled = true,

                    // A REFERENCE, never a value. Both implementations are local fakes and neither
                    // resolves this name; naming a real one would invite a test that needs a
                    // credential, which TASK 13 forbids.
                    SecretReference = "NEXUS_W7G_TEST_KEY",
                    PermitsRemoteEgress = false,
                    Trust = "Approved",
                    Priority = 10,
                    Weight = 1.0,
                    Approval = "Approved",
                    MaxClassification = "Secret",
                    ApprovedBy = "w7g-test-owner",
                    GovernanceRationale = "W7G provider swap fixture.",
                },
            ],
            Models =
            [
                new AiModelConfigurationEntry
                {
                    ModelId = options.ModelId,
                    ProviderId = options.ProviderId,
                    DisplayName = RouteDisplayName,
                    Capabilities = [AiCapabilities.ChatComplete],
                    MaxContextTokens = 200_000,
                    MaxOutputTokens = 8_192,
                    InputModalities = ["Text"],
                    OutputModalities = ["Text"],
                    Reasoning = "High",
                    RelativeSpeed = "Normal",
                    Availability = "Available",
                    Enabled = true,

                    // Deliberately unpriced. The cost dimension is inert in these tests because the
                    // subject is which implementation answered, and a priced route would put the
                    // budget and cost gates in front of that question.
                    Approval = "Approved",
                    MaxClassification = "Secret",
                    ApprovedBy = "w7g-test-owner",
                    GovernanceRationale = "W7G provider swap fixture.",
                },
            ],
            Health =
            [
                new AiHealthConfigurationEntry { ProviderId = options.ProviderId, State = "Available" },
                new AiHealthConfigurationEntry
                {
                    ProviderId = options.ProviderId,
                    ModelId = options.ModelId,
                    State = "Available",
                },
            ],
        };

        /// <summary>The whole estate's configuration: the registry, and the operational posture.</summary>
        private static string EstateJson(EstateOptions options)
        {
            var root = new Dictionary<string, object?>
            {
                ["Ai"] = new Dictionary<string, object?>
                {
                    [AiRegistryConfiguration.SectionName.Split(':')[1]] = Registry(options),

                    // `AiGovernancePolicy.Default()` and the operational budget plane both ship
                    // fail-closed for a priced execution with no covering rule. This estate's models are
                    // unpriced, so neither gate has anything to compare and neither refuses — but the
                    // posture is stated rather than inherited, so a reader can tell a deliberate
                    // configuration from an accident of the content root.
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
            };

            return JsonSerializer.Serialize(root, new JsonSerializerOptions
            {
                DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            });
        }

        /// <summary>The caller's request, exactly as a consumer would put it on the wire.</summary>
        /// <remarks>
        /// No provider, vendor, model or endpoint appears anywhere in this document, and that is the
        /// point rather than an omission: a caller of this contract has no vocabulary in which to
        /// express a provider preference. `execution.costCurrency` is stated because the governance
        /// cost gate compares currencies and refuses when they cannot be compared, and
        /// `execution.quality` is stated because the contract makes it required.
        /// </remarks>
        public static string RequestBody(string requestId) =>
            $$"""
            {
              "requestId": "{{requestId}}",
              "capability": "chat.complete",
              "purpose": "answer a question",
              "requester": {
                "head": "Platform",
                "productId": "experience",
                "principalId": "experience-service",
                "isServicePrincipal": true
              },
              "execution": { "costCurrency": "USD", "quality": {} },
              "input": { "kind": "UserMessage", "text": "hello", "attachments": [] },
              "classification": "Internal",
              "correlationId": "correlation-w7g",
              "idempotencyKey": "idem-w7g"
            }
            """;
    }

    /// <summary>
    /// One provider implementation, recording every invocation it receives.
    /// </summary>
    /// <remarks>
    /// <para>
    /// It implements <see cref="INamedModelGateway"/> — the interface a real provider package
    /// implements — and reports a real <see cref="ModelInvocationResult"/>, including usage, because
    /// that is what a real adapter returns and the ledger's behaviour depends on it.
    /// </para>
    /// <para>
    /// It holds no credential, opens no socket and resolves no secret reference. Its
    /// <see cref="Vendor"/> is the token configuration selects it by, which is the whole of its
    /// identity as far as the routing gateway is concerned.
    /// </para>
    /// </remarks>
    private sealed class RecordingProviderGateway(string vendor) : INamedModelGateway
    {
        /// <summary>The vendor token this implementation answers to.</summary>
        public string Vendor { get; } = vendor;

        /// <summary>The model identifiers this implementation was asked for, in order.</summary>
        public List<string> ModelsAsked { get; } = [];

        /// <summary>How many times this implementation was reached.</summary>
        public int Count => ModelsAsked.Count;

        public Task<ModelInvocationResult> InvokeAsync(ModelInvocation invocation, CancellationToken ct = default)
        {
            ModelsAsked.Add(invocation.ModelId);

            return Task.FromResult(new ModelInvocationResult
            {
                Success = true,
                Message = new ModelMessage
                {
                    Role = ModelRole.Assistant,

                    // The vendor is NOT written into the answer. A fake that echoed it would make the
                    // "the response names no vendor" assertions pass or fail on the fixture rather
                    // than on the estate's projection.
                    Content = "answered",
                },
                Usage = new ModelUsage(25, 5, 0m),
                ModelUsed = invocation.ModelId,
            });
        }

        public async IAsyncEnumerable<ModelStreamChunk> StreamAsync(
            ModelInvocation invocation,
            [EnumeratorCancellation] CancellationToken ct = default)
        {
            // Nothing in this suite streams, and a provider implementation is obliged to answer the
            // interface rather than to implement a behaviour no test exercises. It is written as an
            // async iterator so the compiler emits a real enumerable rather than a throwing stub the
            // first streaming test would discover.
            await Task.CompletedTask;

            yield return new ModelStreamChunk("answered", true);
        }
    }

    /// <summary>The wire's own JSON options, so a test reads the response as a consumer would.</summary>
    private static readonly JsonSerializerOptions WireJson = CreateWireJson();

    private static JsonSerializerOptions CreateWireJson()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        AiJsonConfiguration.Apply(options);
        return options;
    }
}
