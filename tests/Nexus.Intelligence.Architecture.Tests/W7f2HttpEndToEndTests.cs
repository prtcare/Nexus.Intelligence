using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
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
using Nexus.Intelligence.Context.Prompting;
using Nexus.Platform.Contracts.Core;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7F.2 TASK 2: the four scenarios, each driven end to end over real HTTP.
//
// WHAT WAS MISSING, AND WHY IT WAS MISSING RATHER THAN MERELY ABSENT. W7F.1 recorded the gap
// honestly: the four required scenarios were exercised in-process by `W7fGatewayTests`, and the
// HTTP transport was exercised separately by `W7fGatewayHttpBindingTests`, but NO SINGLE TEST drove
// a scenario across the wire. That is not a bookkeeping gap. The one defect this estate actually
// shipped hid in exactly that seam: the gateway answered 400 to every well-formed request while
// every in-memory test passed, because `CapabilityId` serialised but would not deserialise. A suite
// that tests the pipeline in memory and the binding over HTTP, and never the two together, is a
// suite that cannot see the defect it exists to catch.
//
// SO THIS SUITE COMPOSES THE WHOLE PATH AND CROSSES IT. Each test stands up a real Kestrel server
// through the API's own composition root, POSTs a real HTTP request, and asserts on the real HTTP
// response. The path crossed is:
//
//     HTTP -> gateway route -> AiCapabilityGateway -> GovernedTurnExecution -> governance ->
//     registry/router -> IModelStep (the governed fake provider seam) -> operations/audit ->
//     HTTP response
//
// EXACTLY ONE THING IS FAKE, AND IT IS THE THING THE DIRECTIVE SAYS MAY BE. `IModelStep` is the
// seam that leaves the process; it is replaced by a recording fake, registered after the
// composition root so it wins the single-service resolution. Everything else — the gateway, the
// governance evaluator, the registry, the router, the failover selector, the ledger, the audit
// sink, the recorder and the read model — is the estate's own implementation, reached through the
// estate's own wiring. That is what makes these statements about the system rather than about a
// test's stand-in for it.
//
// NO CREDENTIAL, NO NETWORK, NO LIVE PROVIDER. The seam is local, the registry names only secret
// REFERENCES (`NEXUS_W7F2_TEST_KEY`, never a value), and no test reads an environment credential.
public sealed class W7f2HttpEndToEndTests
{
    private const string PrimaryProvider = "prov-w7f2-primary";
    private const string PrimaryModel = "model-w7f2-primary";
    private const string AlternateProvider = "prov-w7f2-alternate";
    private const string AlternateModel = "model-w7f2-alternate";

    // ---------------------------------------------------------------------------------------------
    // Scenario 1 -- successful execution.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task ASuccessfulExecution_CrossesHttpAndTheWholeGovernedPath()
    {
        await using var estate = await Estate.StartAsync(Estate.TwoRoutes(priced: true));

        var (status, response, body) = await estate.PostAsync("req-w7f2-success");

        Assert.True(status == HttpStatusCode.OK, $"a permitted request must be served, got {(int)status}");

        // RequestId preserved: the caller's identifier survives the whole path and comes back as the
        // caller wrote it. Asserted on the serialised body as well as the bound object, because the
        // body is what a consumer actually reads.
        Assert.True(response.RequestId == "req-w7f2-success", $"RequestId must be preserved, got '{response.RequestId}'");
        Assert.True(body.Contains("req-w7f2-success", StringComparison.Ordinal), "the RequestId must cross the wire back");

        Assert.True(
            response.Status == AiExecutionStatus.Succeeded,
            $"the execution must succeed, got {response.Status}; rule '{response.Failure?.Code}', "
            + $"message '{response.Failure?.Message}', policy allowed={response.PolicyDecision?.Allowed}");

        // ExecutionId unique: the estate minted an identity of its own, and it is not the caller's
        // request identifier. This is the W7F TASK 2 property, asserted at the boundary.
        Assert.True(response.Execution is not null, "a served execution must carry an execution reference");
        Assert.True(
            !string.IsNullOrWhiteSpace(response.Execution!.ExecutionId),
            "the execution reference must carry an identifier");
        Assert.True(
            response.Execution.ExecutionId != response.RequestId,
            "the execution identity must not be the caller's request identifier");
        Assert.True(response.AuditReference is not null, "an executed turn must carry an audit reference");

        // NON-VACUITY: the seam proves the governed path was actually traversed. Without this, every
        // assertion above would also pass for a route that answered from a constant.
        Assert.True(estate.Seam.Count == 1, $"the provider seam must have been invoked exactly once, got {estate.Seam.Count}");
        Assert.True(
            estate.Seam.ModelsAsked.Single() == PrimaryModel,
            $"the router must have selected the primary route, got '{estate.Seam.ModelsAsked.Single()}'");

        // Usage and cost evidence: observed by the estate, reported to the caller.
        Assert.True(response.Usage.InputTokens == 40, $"the observed input tokens must be reported, got {response.Usage.InputTokens}");
        Assert.True(response.Usage.OutputTokens == 8, $"the observed output tokens must be reported, got {response.Usage.OutputTokens}");
        Assert.True(response.Cost is not null, "a priced route must report a cost rather than an absence");

        // ...and recorded in the estate's own ledgers, which is the operations/audit half of the path.
        var usage = estate.Ledger.Entries();
        Assert.True(usage.Count == 1, $"exactly one usage entry must be recorded, got {usage.Count}");
        Assert.True(usage[0].ExecutionId == response.Execution.ExecutionId, "the usage entry must name the execution the caller was given");
        Assert.True(usage[0].RequestId == "req-w7f2-success", "the usage entry must carry the caller's request identifier");

        var audit = estate.Audit.Recent(50);
        Assert.True(audit.Count >= 1, $"the audit sink must hold a record of the execution, got {audit.Count}");

        // No vendor leakage: nothing on the response names what served it.
        AssertDoesNotNameTheEstate(response);
    }

    // ---------------------------------------------------------------------------------------------
    // Scenario 2 -- governance/policy blocked.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AGovernanceBlockedExecution_CrossesHttpAndCarriesATypedProviderNeutralFailure()
    {
        // The model is registered and healthy, and it is not approved. The refusal therefore comes
        // from governance, not from routing and not from health -- which is what makes this a test of
        // the policy gate rather than of an empty registry.
        await using var estate = await Estate.StartAsync(Estate.Blocked());

        var (status, response, body) = await estate.PostAsync("req-w7f2-blocked");

        Assert.True(status == HttpStatusCode.OK, $"a governance refusal is a served answer, not a transport error, got {(int)status}");

        Assert.True(response.RequestId == "req-w7f2-blocked", $"RequestId must be preserved through a refusal, got '{response.RequestId}'");
        Assert.True(response.Status == AiExecutionStatus.Blocked, $"the verdict must be reported as blocked, got {response.Status}");

        // Typed, provider-neutral failure: a category the caller can branch on, not prose.
        Assert.True(response.Failure is not null, "a blocked execution must carry a typed failure");
        Assert.True(
            response.Failure!.Category == AiFailureCategory.PolicyBlocked,
            $"the category must name the gate that refused it, got {response.Failure.Category}");
        Assert.True(
            response.Failure.Category != AiFailureCategory.Unspecified,
            "an unspecified category is not a typed failure");
        Assert.True(
            !string.IsNullOrWhiteSpace(response.Failure.Code),
            "the failure must carry a rule identifier a caller can act on");

        // The rule, not merely a rule. Any refusal would satisfy "carries a code"; naming the approval
        // gate is what proves the request reached governance, was assessed against the model's approval
        // status, and was refused there -- rather than being refused earlier for a reason this test
        // does not examine.
        Assert.True(
            response.Failure.Code == AiGovernanceRules.ModelNotApproved,
            $"the refusal must name the approval gate, got '{response.Failure.Code}'");

        // NON-VACUITY: the request was refused before anything was invoked. A governance refusal that
        // still reached a provider would be a block in name only.
        Assert.True(estate.Seam.Count == 0, $"nothing may be invoked under a refusal, seam reached {estate.Seam.Count} time(s)");

        // A refusal CARRIES the execution it refused, and that is the contract rather than a leak.
        // `AiExecutionReference` is absent on a DEGRADED result -- where nothing ran and there is no
        // execution to name -- and a blocked execution is a different thing: it exists, it was
        // assessed, and it was refused, so a caller that wants to dispute the refusal has something
        // to dispute. The absence of a reference here would be the estate claiming it never saw the
        // request. What must be absent is any trace of work.
        Assert.True(
            response.Execution is not null,
            "a blocked execution is still an execution, and the caller must be able to reference it");
        Assert.True(
            response.Execution!.ExecutionId != response.RequestId,
            "the execution reference must be its own identifier, not the caller's echoed RequestId");
        Assert.True(estate.Ledger.Entries().Count == 0, "a refused execution must record no usage");

        // -----------------------------------------------------------------------------------------
        // W7F.2 FINDING, PINNED RATHER THAN HIDDEN: THE TYPED REFUSAL IS NEUTRAL, THE PROSE IS NOT.
        // -----------------------------------------------------------------------------------------
        //
        // The typed half is what a caller branches on, and it is provider-neutral: the category is the
        // contract's `PolicyBlocked` and the code is the contract's rule identifier. Asserted above.
        //
        // The prose half is not. `AiGovernanceDecision.ToFailure` carries `Reason` as the failure
        // message, and the approval gate's reason is written for an operator -- "Model '<id>' is
        // 'Suspended' and may not be used." -- so the registered model identifier reaches the caller
        // over `Failure.Message` AND over `PolicyDecision.Reason`. On the success path the boundary
        // removes provider and model and replaces them with an opaque reference; on this path the same
        // identifiers it just removed arrive in a sentence.
        //
        // NOT FIXED HERE, and the reason is scope rather than severity. The refusal is correct, its
        // typed fields are correct, no vendor exception crosses, and narrowing the operator's reason
        // is a governance-semantics change -- which a closure stage is the wrong place to make. What a
        // closure stage owes is that the behaviour is recorded and cannot drift unnoticed, so the
        // assertion below PINS it. If it starts failing, the disclosure was closed: update this
        // assertion and the W7F.2 carry-forward together, rather than deleting either.
        var rendered = response.ToString();
        Assert.True(
            rendered.Contains(PrimaryProvider, StringComparison.Ordinal)
            || rendered.Contains(PrimaryModel, StringComparison.Ordinal),
            "known disclosure: a governance refusal's prose names the route it refused. This assertion "
            + "pins a recorded W7F.2 finding, not a desired behaviour.");

        // The parts that MUST be neutral, asserted separately so the pin above cannot mask a regression
        // in them: no provider identity in the typed failure, and no vendor exception text anywhere.
        Assert.True(
            !response.Failure!.Category.ToString().Contains("Provider", StringComparison.OrdinalIgnoreCase),
            $"the failure category must be provider-neutral, got {response.Failure.Category}");
        Assert.True(
            !body.Contains(SeamModelStep.VendorText, StringComparison.OrdinalIgnoreCase),
            "no vendor exception text may cross the HTTP boundary on any path");
    }

    // ---------------------------------------------------------------------------------------------
    // Scenario 3 -- fallback.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AFallback_CrossesHttpAndIsReportedWithoutNamingWhatReplacedIt()
    {
        // The primary route fails when asked, so the router selects it and the failover plane
        // replaces it. Both routes are registered, approved, healthy and priced under the fixture's
        // declared ceiling; only the first fails.
        await using var estate = await Estate.StartAsync(
            Estate.TwoRoutes(failingModels: [PrimaryModel], priced: true));

        var (status, response, _) = await estate.PostAsync("req-w7f2-fallback");

        Assert.True(status == HttpStatusCode.OK, $"a completed fallback is a served answer, got {(int)status}");
        Assert.True(response.RequestId == "req-w7f2-fallback", $"RequestId must be preserved, got '{response.RequestId}'");
        Assert.True(
            response.Status == AiExecutionStatus.Succeeded,
            $"the fallback must complete, got {response.Status}; rule '{response.Failure?.Code}', "
            + $"message '{response.Failure?.Message}', policy allowed={response.PolicyDecision?.Allowed}");

        // Fallback evidence: the caller is told its answer came from a secondary route...
        Assert.True(response.UsedFallback, "the caller must be told a fallback served it");

        // ...and told nothing else. A completed fallback produced a real answer, so it is NOT a
        // degraded result; deriving one from the other would report a clean fallback as a failure.
        Assert.True(!response.IsDegraded, "a completed fallback is not a degraded result");

        // NON-VACUITY: both routes were really asked, in order, so the flag is evidence of a failover
        // rather than a constant the gateway sets.
        Assert.True(estate.Seam.Count == 2, $"the seam must record both attempts, got {estate.Seam.Count}");
        Assert.True(
            estate.Seam.ModelsAsked[0] == PrimaryModel && estate.Seam.ModelsAsked[1] == AlternateModel,
            $"the failover must run primary then alternate, got '{string.Join(", ", estate.Seam.ModelsAsked)}'");

        // The estate's own ledgers record the fallback, so the projection withholding the route name
        // is a withholding rather than the estate never having known it.
        var usage = estate.Ledger.Entries();
        Assert.True(usage.Count >= 2, $"both attempts must be recorded in the usage ledger, got {usage.Count}");
        Assert.True(usage.Any(entry => entry.IsFallback), "the usage ledger must record the fallback attempt");
        Assert.True(
            usage.Any(entry => entry.ModelId == AlternateModel),
            "the usage ledger must name the route that actually served");

        AssertDoesNotNameTheEstate(response);
    }

    // ---------------------------------------------------------------------------------------------
    // Scenario 4 -- AI unavailable.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AnUnavailableEstate_IsContainedOverHttpWithNoExecutionReference()
    {
        // Every declared route is unavailable. The estate is composed and reachable; it simply has
        // nothing it can run. Declared through health rather than by degrading the container, so the
        // refusal comes from the availability projection the gateway actually reads.
        await using var estate = await Estate.StartAsync(Estate.Unavailable());

        var (status, response, _) = await estate.PostAsync("req-w7f2-unavailable");

        Assert.True(status == HttpStatusCode.OK, $"an unavailable estate is a served answer, got {(int)status}");
        Assert.True(response.RequestId == "req-w7f2-unavailable", $"RequestId must be preserved, got '{response.RequestId}'");

        Assert.True(
            response.Status is AiExecutionStatus.Failed or AiExecutionStatus.Degraded,
            $"an unavailable estate must not report success, got {response.Status}");

        // Typed and provider-neutral: the category names the Head's own condition, not a vendor's.
        Assert.True(response.Failure is not null, "an unavailable estate must carry a typed failure");
        Assert.True(
            response.Failure!.Category == AiFailureCategory.AiUnavailable,
            $"the category must be the neutral availability one, got {response.Failure.Category}");

        // Nothing ran, so there is no execution identity to hand the caller.
        Assert.True(response.Execution is null, "nothing executed, so no execution may be referenced");
        Assert.True(estate.Seam.Count == 0, $"nothing may be invoked while unavailable, seam reached {estate.Seam.Count} time(s)");
        Assert.True(estate.Ledger.Entries().Count == 0, "nothing ran, so nothing may be metered");

        AssertDoesNotNameTheEstate(response);
    }

    // ---------------------------------------------------------------------------------------------
    // The containment property, driven over the wire rather than in memory.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AVendorException_DoesNotCrossTheHttpBoundary()
    {
        // The seam raises a provider SDK's exception, in the shape the boundary exists to contain.
        // This is the one failure mode where prose from below would otherwise reach a caller.
        await using var estate = await Estate.StartAsync(Estate.TwoRoutes(throwingModels: [PrimaryModel, AlternateModel]));

        var (status, response, body) = await estate.PostAsync("req-w7f2-vendor");

        Assert.True(status == HttpStatusCode.OK, $"a contained vendor failure is a served answer, got {(int)status}");

        // The vendor's own words must not appear anywhere the caller can read them - not in the typed
        // failure, and not in the serialised body.
        Assert.True(response.Failure is not null, "a contained failure must still be reported to the caller");
        Assert.True(
            !response.Failure!.Message.Contains(SeamModelStep.VendorText, StringComparison.OrdinalIgnoreCase),
            "the vendor exception's own text must not be reproduced in the failure message");
        Assert.True(
            !body.Contains(SeamModelStep.VendorText, StringComparison.OrdinalIgnoreCase),
            "the vendor exception's own text must not appear anywhere in the response body");

        AssertDoesNotNameTheEstate(response);
    }

    // ---------------------------------------------------------------------------------------------
    // Assertions
    // ---------------------------------------------------------------------------------------------

    /// <summary>
    /// Asserts that nothing on the caller-facing response discloses what served it.
    /// </summary>
    /// <remarks>
    /// Over the rendered response rather than field by field, so a member added later is covered
    /// without anyone remembering to extend this helper. The record's own <c>ToString</c> prints
    /// every member and recurses into the nested records, which is the surface a leaked route name
    /// would travel over.
    /// </remarks>
    private static void AssertDoesNotNameTheEstate(AiCapabilityResponse response)
    {
        var rendered = response.ToString();

        Assert.True(
            !rendered.Contains(PrimaryModel, StringComparison.OrdinalIgnoreCase)
            && !rendered.Contains(AlternateModel, StringComparison.OrdinalIgnoreCase)
            && !rendered.Contains(PrimaryProvider, StringComparison.OrdinalIgnoreCase)
            && !rendered.Contains(AlternateProvider, StringComparison.OrdinalIgnoreCase),
            "the caller-facing response must name no model and no provider");
    }

    // ---------------------------------------------------------------------------------------------
    // The estate under test
    // ---------------------------------------------------------------------------------------------

    /// <summary>A running real HTTP estate, with the seams a test asserts on.</summary>
    private sealed class Estate : IAsyncDisposable
    {
        private WebApplication _app = null!;

        public required HttpClient Client { get; init; }

        /// <summary>The provider seam, recording every invocation it receives.</summary>
        public required SeamModelStep Seam { get; init; }

        /// <summary>The estate's usage and cost ledger, as the operations read model reads it.</summary>
        public required InMemoryAiOperationsLedger Ledger { get; init; }

        /// <summary>The estate's audit sink, read through the same port the operations surface uses.</summary>
        public required InMemoryAiAuditSink Audit { get; init; }

        /// <summary>Boots the estate through the API's own composition root.</summary>
        public static async Task<Estate> StartAsync(EstateOptions options)
        {
            var builder = WebApplication.CreateSlimBuilder();

            builder.WebHost.UseUrls("http://127.0.0.1:0");

            // =========================================================================================
            // THE ESTATE'S CONFIGURATION IS DECLARED HERE AND NOWHERE ELSE.
            // =========================================================================================
            //
            // `CreateSlimBuilder` loads `appsettings.json` from the content root, and this test project
            // references the API project, so the API's OWN `appsettings.json` is copied into this test's
            // output directory and would be read. Two things follow from that, and both are defects in a
            // test that claims to be deterministic:
            //
            //   1. ARRAYS MERGE BY INDEX, THEY DO NOT REPLACE. `Ai:Registry:Models` from the API's file
            //      is flattened to `Ai:Registry:Models:0:ModelId`, `:1:...`, `:2:...`; this fixture's two
            //      models overwrite indices 0 and 1 and LEAVE EVERY HIGHER INDEX STANDING. The estate
            //      would then route over models the test never registered, and the test would be reading
            //      the API's configuration while appearing to read its own.
            //
            //   2. THE SHIPPED POSTURE IS FAIL-CLOSED, SO INHERITING IT SILENTLY IS A DECISION.
            //      `Operations:Budget` ships `OnUncoveredPricedExecution: Refuse` with no rules, which
            //      means the operational budget gate refuses every priced route in this estate. That is
            //      the correct shipped posture and it is NOT what these scenarios are about -- but a
            //      fixture that acquires it by inheritance cannot say so, and a reader cannot tell a
            //      deliberate posture from an accident of the content root.
            //
            // So the sources are cleared and one document is supplied. Everything the estate reads is
            // in `EstateJson`, including the budget rule the priced scenarios run under. Nothing is
            // inherited and nothing is ambient.
            builder.Configuration.Sources.Clear();
            builder.Configuration.AddJsonStream(new MemoryStream(Encoding.UTF8.GetBytes(EstateJson(options))));

            // The two ports the API project supplies itself, in Program.cs's order.
            builder.Services.AddSingleton<IToolCatalog, EmptyToolCatalog>();
            builder.Services.AddSingleton<IToolGateway, EmptyToolGateway>();

            builder.Services.AddNexusIntelligence(builder.Configuration);

            // THE ESTATE'S CEILING, SUPPLIED WHERE THE ESTATE ACTUALLY READS ONE.
            //
            // There are two budget tables and they answer two different questions, which is why both
            // are written down:
            //
            //   * `Operations:Budget:Rules` (in `EstateJson`) is the OPERATIONAL plane's ceiling table,
            //     read by the router's cost gate. It is configuration, so it is configured.
            //   * `AiGovernancePolicy.Budgets` is the GOVERNANCE plane's ceiling table, read by the
            //     evaluator's cost stage. It has no configuration binding at all -- the composition root
            //     builds the policy with `with` from `Default()`, which leaves `Budgets` empty.
            //
            // So the governance ceiling has to be supplied as a policy, and that is the ONLY way to
            // supply one. Note what is NOT happening here: `RequireBudgetRuleForPricedExecution` is
            // left at its shipped `true`. An earlier revision of this fixture set it to `false`, on the
            // W7D harness's precedent, so that a priced route could run with no ceiling anywhere. That
            // was working around the gate rather than configuring the estate -- the gate was right, and
            // what was missing was a ceiling. Switching it off would also have meant these scenarios
            // never exercised the cost gate at all.
            //
            // The override WRAPS the composition root's own registration rather than adding a second
            // one. A second registration of the same service type would be the one a later resolve
            // returns, and a factory that then asked the container for the policy would be asking for
            // itself. Editing the existing descriptor keeps exactly one policy in the container, so
            // there is no second answer anywhere for anything to disagree with. Everything else the
            // composition root puts in the policy -- the register, the tool rules, the exposure table,
            // the capability register -- is the estate's own.
            var policyIndex = builder.Services.ToList().FindIndex(d => d.ServiceType == typeof(AiGovernancePolicy));
            var shippedPolicy = builder.Services[policyIndex];
            var buildShippedPolicy = shippedPolicy.ImplementationFactory!;
            builder.Services[policyIndex] = new ServiceDescriptor(
                typeof(AiGovernancePolicy),
                provider => ((AiGovernancePolicy)buildShippedPolicy(provider)) with
                {
                    Budgets =
                    [
                        new AiGovernanceBudgetRule
                        {
                            RuleId = "w7f2.chat-complete.ceiling",
                            Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
                            Ceiling = 1.00m,
                            Currency = "USD",
                            OnExceeded = AiGovernanceVerdict.Block,
                            Rationale = "W7F.2 HTTP end-to-end fixture. One US dollar bounds a single "
                                + "chat.complete execution, which at the rates declared on the fixture's "
                                + "models is many orders of magnitude above the projected cost. The ceiling "
                                + "exists so the estate states a number rather than so the number is reached.",
                        },
                    ],
                },
                shippedPolicy.Lifetime);

            builder.Services.AddSingleton(TimeProvider.System);
            builder.Services.AddProblemDetails();
            builder.Services.ConfigureHttpJsonOptions(
                http => AiJsonConfiguration.Apply(http.SerializerOptions));

            // The seam, registered last so it wins the single-service resolution. This is the ONLY
            // substitution in the whole estate, and it is the seam the directive permits.
            var seam = new SeamModelStep(options.FailingModels, options.ThrowingModels, options.TokensIn, options.TokensOut);
            builder.Services.AddSingleton<IModelStep>(seam);

            var app = builder.Build();
            app.MapGatewayEndpoints();
            await app.StartAsync();

            return new Estate
            {
                _app = app,
                Client = new HttpClient { BaseAddress = new Uri(app.Urls.First()) },
                Seam = seam,
                Ledger = app.Services.GetRequiredService<InMemoryAiOperationsLedger>(),
                Audit = app.Services.GetRequiredService<InMemoryAiAuditSink>(),
            };
        }

        /// <summary>POSTs one capability request at the real gateway route.</summary>
        public async Task<(HttpStatusCode Status, AiCapabilityResponse Response, string Body)> PostAsync(string requestId)
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, $"{AiGatewayContract.RoutePrefix}/invoke")
            {
                Content = new StringContent(RequestBody(requestId), Encoding.UTF8, "application/json"),
            };
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

        // ---- fixtures ---------------------------------------------------------------------------

        /// <summary>Two approved, healthy routes, with the primary ahead of the alternate.</summary>
        /// <remarks>
        /// <b>The primary carries the HIGHER priority number, because higher is preferred.</b>
        /// `AiProviderRegistration.Priority` is documented as an ordinal preference where higher wins
        /// -- the opposite of the intuition that "priority 1" outranks "priority 10". Both routes are
        /// otherwise identical (same capability, same approvals, same health, same rates), so a fixture
        /// that got this backwards would still run: it would simply select the alternate first, and
        /// the two scenarios that depend on WHICH route serves would quietly assert the wrong thing.
        /// This one did, and the fallback scenario is what caught it -- a failover cannot be observed
        /// when the route that is supposed to fail was never chosen.
        /// </remarks>
        public static EstateOptions TwoRoutes(
            IReadOnlyList<string>? failingModels = null,
            IReadOnlyList<string>? throwingModels = null,
            bool priced = false) => new()
            {
                Providers =
                [
                    Provider(PrimaryProvider, priority: 20),
                    Provider(AlternateProvider, priority: 10),
                ],
                Models =
                [
                    Model(PrimaryModel, PrimaryProvider, priced),
                    Model(AlternateModel, AlternateProvider, priced),
                ],
                Health =
                [
                    HealthRow(PrimaryProvider, null, "Available"),
                    HealthRow(PrimaryProvider, PrimaryModel, "Available"),
                    HealthRow(AlternateProvider, null, "Available"),
                    HealthRow(AlternateProvider, AlternateModel, "Available"),
                ],
                FailingModels = failingModels ?? [],
                ThrowingModels = throwingModels ?? [],
                TokensIn = 40,
                TokensOut = 8,
            };

        /// <summary>One registered, healthy, suspended model, so governance is what refuses.</summary>
        /// <remarks>
        /// Registered and healthy on purpose. An estate that refused because it declared no routes
        /// would be testing an empty registry, and the assertion on the failure CATEGORY is what tells
        /// those two apart.
        /// <para>
        /// <b>The approval status is one of the four the estate names, and the name is load-bearing.</b>
        /// The set is closed -- Unregistered, Approved, Suspended, Retired -- and the engine reports the
        /// status it read. <c>Suspended</c> is the honest one here: the model exists, it is configured,
        /// it is healthy, and it has been taken out of service. A fixture that wanted a model which was
        /// never registered would be testing a different gate.
        /// </para>
        /// </remarks>
        public static EstateOptions Blocked() => new()
        {
            Providers = [Provider(PrimaryProvider, priority: 10)],
            Models = [Model(PrimaryModel, PrimaryProvider, priced: false, approval: "Suspended")],
            Health =
            [
                HealthRow(PrimaryProvider, null, "Available"),
                HealthRow(PrimaryProvider, PrimaryModel, "Available"),
            ],
        };

        /// <summary>One registered, approved model whose health is Unavailable.</summary>
        public static EstateOptions Unavailable() => new()
        {
            Providers = [Provider(PrimaryProvider, priority: 10)],
            Models = [Model(PrimaryModel, PrimaryProvider, priced: false)],
            Health =
            [
                HealthRow(PrimaryProvider, null, "Unavailable"),
                HealthRow(PrimaryProvider, PrimaryModel, "Unavailable"),
            ],
        };

        private static AiProviderConfigurationEntry Provider(string providerId, int priority) => new()
        {
            ProviderId = providerId,
            DisplayName = providerId,
            AdapterIdentity = "Nexus.Intelligence.Architecture.Tests.Adapter",
            Capabilities = [AiCapabilities.ChatComplete],
            Enabled = true,

            // A REFERENCE, never a value. No test in this suite has a credential to give and none needs
            // one; the seam is local and nothing resolves this name.
            //
            // It is a FIXTURE identifier and not a convention. The estate's approved default reference
            // is `NEXUS_OPENAI_API_KEY`, and this is deliberately not that: nothing here should suggest
            // a test needs a real credential, and naming the real one would invite exactly that. The
            // project-prefixed shape is kept because the standing rule is that a secret reference
            // carries an approved project name rather than a vendor-conventional one.
            SecretReference = "NEXUS_W7F2_TEST_KEY",
            PermitsRemoteEgress = false,
            Trust = "Approved",
            Priority = priority,
            Weight = 1.0,
            Approval = "Approved",
            MaxClassification = "Secret",
            ApprovedBy = "w7f2-test-owner",
            GovernanceRationale = "W7F.2 HTTP end-to-end fixture.",
        };

        private static AiModelConfigurationEntry Model(
            string modelId,
            string providerId,
            bool priced,
            string approval = "Approved") => new()
            {
                ModelId = modelId,
                ProviderId = providerId,
                DisplayName = modelId,
                Capabilities = [AiCapabilities.ChatComplete],
                MaxContextTokens = 200_000,
                MaxOutputTokens = 8_192,
                InputModalities = ["Text"],
                OutputModalities = ["Text"],
                Reasoning = "High",
                RelativeSpeed = "Normal",
                Availability = "Available",
                Enabled = true,
                InputCostPer1kTokens = priced ? 0.50m : null,
                OutputCostPer1kTokens = priced ? 1.50m : null,
                CostCurrency = priced ? "USD" : null,
                CostMetadataReference = priced ? "W7F.2 HTTP end-to-end fixture." : null,
                Approval = approval,
                MaxClassification = "Secret",
                ApprovedBy = approval == "Approved" ? "w7f2-test-owner" : null,
                GovernanceRationale = "W7F.2 HTTP end-to-end fixture.",
            };

        private static AiHealthConfigurationEntry HealthRow(string providerId, string? modelId, string state) => new()
        {
            ProviderId = providerId,
            ModelId = modelId,
            State = state,
        };

        /// <summary>
        /// The whole estate's configuration: the registry, and the operational budget the priced
        /// routes run under.
        /// </summary>
        /// <remarks>
        /// One document, so that what the estate is configured with is readable in one place and is
        /// not assembled from a file the test does not own. See the clearing of the configuration
        /// sources in <see cref="Estate.StartAsync"/> for why the second half exists at all.
        /// </remarks>
        private static string EstateJson(EstateOptions options)
        {
            var configuration = new AiRegistryConfiguration
            {
                Provenance = "W7F.2 HTTP end-to-end fixture.",
                Routing = new AiRoutingConfigurationEntry { Objective = "Balanced", FallbackDepth = options.FallbackDepth },
                Providers = [.. options.Providers],
                Models = [.. options.Models],
                Health = [.. options.Health],
            };

            var root = new Dictionary<string, object?>
            {
                ["Ai"] = new Dictionary<string, object?>
                {
                    [AiRegistryConfiguration.SectionName.Split(':')[1]] = configuration,

                    // THE CEILING THE PRICED SCENARIOS RUN UNDER, and the reason the governance cost
                    // gate no longer has to be switched off for them to pass.
                    //
                    // `AiGovernancePolicy.Default()` refuses a priced execution with no covering budget
                    // rule, and `AiOperationsBudgetPolicy` refuses an *uncovered priced* execution by
                    // default too. Those are two gates stating one fact and both are shipped closed, so
                    // an estate that means to spend on a priced route has to say what the ceiling is.
                    //
                    // This is that statement. The semantics of the value matter less than its being
                    // written down: it is deliberately far above the fixture's projected cost (a
                    // fraction of a cent at the rates declared on the models), so it admits the route
                    // by covering it rather than by being too large to reach -- a ceiling the route
                    // cannot approach would be an allowance, not a control. The rate is asserted
                    // indirectly by the success scenario, which reports a real cost against this rule.
                    ["Operations"] = new Dictionary<string, object?>
                    {
                        ["Budget"] = new Dictionary<string, object?>
                        {
                            ["Available"] = true,
                            ["OnUncoveredPricedExecution"] = "Refuse",
                            ["OnUnpricedExecution"] = "Allow",
                            ["Rules"] = new object[]
                            {
                                new Dictionary<string, object?>
                                {
                                    ["RuleId"] = "w7f2.chat-complete.per-execution",
                                    ["Capability"] = AiCapabilities.ChatComplete,
                                    ["Ceiling"] = 1.00m,
                                    ["Currency"] = "USD",
                                    ["Period"] = "None",
                                    ["OnExceeded"] = "Block",
                                    ["Rationale"] = "W7F.2 HTTP end-to-end fixture. One US dollar bounds a "
                                        + "single chat.complete execution, which at the rates declared on the "
                                        + "fixture's models is many orders of magnitude above the projected "
                                        + "cost. The ceiling exists so the estate states a number rather "
                                        + "than so the number is reached.",
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

        /// <summary>A well-formed capability request, as a consumer would put it on the wire.</summary>
        /// <remarks>
        /// <para>
        /// <c>execution.costCurrency</c> is stated even though no <c>maxCost</c> ceiling is set, and
        /// that is a requirement rather than a decoration. The governance cost gate compares the
        /// execution's currency against the covering rule's currency and refuses when they cannot be
        /// compared -- including when the caller names none, because "a number whose unit nobody
        /// stated" is not a wildcard. A caller that will be billed states its unit.
        /// </para>
        /// <para>
        /// <c>execution.quality</c> is stated because the contract makes it <c>required</c>: stating
        /// any execution policy without it is refused by the deserialiser with a 400 before any
        /// governance runs. An empty object is the contract's own "complete answer, no structural
        /// requirement" -- <see cref="AiQualityRequirement.Complete"/> -- written as a value rather
        /// than left to a default the contract deliberately does not supply.
        /// </para>
        /// </remarks>
        private static string RequestBody(string requestId) =>
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
              "correlationId": "correlation-w7f2",
              "idempotencyKey": "idem-w7f2"
            }
            """;
    }

    /// <summary>The knobs an estate fixture sets.</summary>
    private sealed record EstateOptions
    {
        public IReadOnlyList<AiProviderConfigurationEntry> Providers { get; init; } = [];
        public IReadOnlyList<AiModelConfigurationEntry> Models { get; init; } = [];
        public IReadOnlyList<AiHealthConfigurationEntry> Health { get; init; } = [];
        public int FallbackDepth { get; init; } = 1;
        public IReadOnlyList<string> FailingModels { get; init; } = [];
        public IReadOnlyList<string> ThrowingModels { get; init; } = [];
        public int TokensIn { get; init; }
        public int TokensOut { get; init; }
    }

    /// <summary>
    /// The governed fake provider seam: the one thing in the estate that stands in for a provider.
    /// </summary>
    /// <remarks>
    /// It reports a real <c>ModelInvocationResult</c>, including usage, because that is what a real
    /// seam returns and the ledger's behaviour depends on it. A failed call still reports what it
    /// consumed — reporting zero would make a failing route look free and would hide the failed
    /// attempt's spend from the ledger, which is exactly the reporting a reliability incident needs.
    /// </remarks>
    private sealed class SeamModelStep : IModelStep
    {
        /// <summary>The vendor's own words, which must never reach a caller.</summary>
        public const string VendorText = "vendor-sdk-internal-trace-8821";

        private readonly HashSet<string> _failing;
        private readonly HashSet<string> _throwing;
        private readonly ModelUsage _usage;

        public SeamModelStep(
            IReadOnlyList<string> failing,
            IReadOnlyList<string> throwing,
            int tokensIn,
            int tokensOut)
        {
            _failing = [.. failing];
            _throwing = [.. throwing];
            _usage = new ModelUsage(tokensIn, tokensOut, 0m);
        }

        public List<string> ModelsAsked { get; } = [];

        public int Count => ModelsAsked.Count;

        public Task<ModelStepResult> InvokeAsync(
            AssembledPrompt prompt,
            string modelId,
            IReadOnlyList<ToolDescriptor> tools,
            InvocationIdentity identity,
            decimal? maxCost,
            CancellationToken ct = default)
        {
            ModelsAsked.Add(modelId);

            if (_throwing.Contains(modelId))
            {
                // A provider SDK's exception, in the shape the boundary exists to contain. Its text is
                // the vendor's own and names internals a caller has no business reading.
                throw new VendorSdkException($"{VendorText}: request rejected by provider runtime");
            }

            if (_failing.Contains(modelId))
            {
                return Task.FromResult(new ModelStepResult(
                    new ModelInvocationResult
                    {
                        Success = false,
                        Error = $"the seam fails '{modelId}' by request",
                        Usage = _usage,
                        ModelUsed = modelId,
                    },
                    new DecisionTrace($"Invoked model '{modelId}'", "W7F.2 seam: declared failing.", []))
                {
                    TokensIn = _usage.TokensIn,
                    TokensOut = _usage.TokensOut,
                });
            }

            return Task.FromResult(new ModelStepResult(
                new ModelInvocationResult
                {
                    Success = true,
                    Message = new ModelMessage { Role = ModelRole.Assistant, Content = "answered" },
                    Usage = _usage,
                    ModelUsed = modelId,
                },
                new DecisionTrace($"Invoked model '{modelId}'", "W7F.2 seam.", []))
            {
                TokensIn = _usage.TokensIn,
                TokensOut = _usage.TokensOut,
            });
        }
    }

    /// <summary>A provider SDK's exception, in the shape the boundary exists to contain.</summary>
    private sealed class VendorSdkException : Exception
    {
        public VendorSdkException(string message)
            : base(message)
        {
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
