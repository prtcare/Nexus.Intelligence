using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Gateway;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Turns;
using Nexus.Intelligence.Tests.Operations;
using Nexus.Intelligence.Tests.Turns;
using Nexus.Platform.Contracts.Tools;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Gateway;

// W7F TASK 2, TASK 3, TASK 11 and TASK 13: the gateway's translation onto the governed path, its
// projection back onto the caller-facing contract, and the two things it must never carry.
//
// WHY THESE TESTS RUN OVER THE REAL PATH RATHER THAN A DOUBLE. The gateway's whole job is that a
// semantic request reaches a provider through the governed execution path and nothing else. A test
// composed over a stubbed execution would assert that the gateway called the stub, which is a fact
// about the test. Composed over GovernedPath, "no provider was reached" is a count of zero on the
// recording model seam, and "provider and model never left the boundary" is asserted against a
// response produced by the estate's own router, governance engine, ledger and audit sink.
public sealed class W7fGatewayTests
{
    // ---------------------------------------------------------------------------------------------
    // TASK 1 and TASK 3: a semantic request is served, and the answer names no route.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task ASemanticRequest_IsServed_AndTheAnswerNamesNoRoute()
    {
        var path = GovernedPath.Compose(TwoRoutes(tokensIn: 100, tokensOut: 20));
        var gateway = GatewayFor(path);

        var response = await gateway.InvokeAsync(Request("req-w7f-served"));

        Assert.Equal(AiExecutionStatus.Succeeded, response.Status);
        Assert.Equal("req-w7f-served", response.RequestId);
        Assert.Equal(AiCapabilities.ChatComplete, response.Capability.Value);
        Assert.NotNull(response.Output);

        // TASK 3: provider and model are evidence of what AI Head selected, not something a caller
        // receives. The caller receives an opaque handle to the execution instead.
        Assert.NotNull(response.Execution);
        Assert.False(string.IsNullOrWhiteSpace(response.Execution!.ExecutionId));
        Assert.NotNull(response.AuditReference);

        // The execution reference resolves to an identity the AI Head minted rather than the caller's
        // request identifier - W7F TASK 2, asserted at the boundary and not only inside the path.
        Assert.NotEqual(response.RequestId, response.Execution.ExecutionId);
        Assert.False(response.UsedFallback);
        Assert.Null(response.Failure);
        Assert.NotNull(response.Elapsed);
        Assert.True(response.PolicyDecision!.Allowed);

        // Nothing on the response discloses what served it. Asserted over the rendered shape rather
        // than field by field, so a member added later cannot pass by not being inspected.
        var rendered = Render(response);

        Assert.DoesNotContain(PrimaryModel, rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(AlternateModel, rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(PrimaryProvider, rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(AlternateProvider, rendered, StringComparison.OrdinalIgnoreCase);

        // NON-VACUITY: the router really did choose one of those routes, so the assertions above are
        // about a name being withheld rather than a name that never existed in the execution.
        Assert.Equal(PrimaryModel, path.Ledger.Entries().Single().ModelId);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 3: fallback is reported to the caller without naming what it fell back to.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AFallback_IsReportedToTheCaller_WithoutNamingTheRouteThatReplaced()
    {
        // The primary fails when asked, so the router selects it and the failover plane replaces it.
        var path = GovernedPath.Compose(TwoRoutes(failingModels: [PrimaryModel]));
        var gateway = GatewayFor(path);

        var response = await gateway.InvokeAsync(Request("req-w7f-fallback"));

        Assert.Equal(AiExecutionStatus.Succeeded, response.Status);
        Assert.True(response.UsedFallback, "The caller is told its answer came from a secondary route.");

        // ...and is told nothing else. A fallback completed and produced a real answer, so it is NOT a
        // degraded result: the two are independent, and a build that derived one from the other would
        // report a successful fallback as though nothing had run.
        Assert.False(response.IsDegraded);

        var rendered = Render(response);

        Assert.DoesNotContain(PrimaryModel, rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(AlternateModel, rendered, StringComparison.OrdinalIgnoreCase);

        // NON-VACUITY: the failover record exists and names both routes, so the absence above is the
        // projection withholding them rather than the estate never having recorded them.
        var entries = path.Ledger.Entries();

        Assert.Contains(entries, entry => entry.IsFallback);
        Assert.Contains(entries, entry => entry.ModelId == AlternateModel);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 5 and TASK 3: cost is a figure or an absence, never a zero standing in for "unknown".
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AnUnpricedExecution_ReportsNoCost_RatherThanZero()
    {
        // Neither route states rates, so the estate has no price for what it spent.
        var path = GovernedPath.Compose(TwoRoutes(tokensIn: 1_000, tokensOut: 1_000));
        var gateway = GatewayFor(path);

        var response = await gateway.InvokeAsync(Request("req-w7f-unpriced"));

        Assert.Equal(AiExecutionStatus.Succeeded, response.Status);

        // Tokens are known and reported: the estate observed them.
        Assert.Equal(1_000, response.Usage.InputTokens);
        Assert.Equal(1_000, response.Usage.OutputTokens);

        // The cost is not. Zero would be a claim that the execution cost nothing, and the estate does
        // not know that - it knows it has no price for it.
        Assert.Null(response.Cost);

        // NON-VACUITY: the same projection reports a real figure when the estate can price the route,
        // so the null above is a reading rather than a constant.
        var pricedPath = GovernedPath.Compose(Priced(tokensIn: 1_000, tokensOut: 1_000));
        var priced = await GatewayFor(pricedPath).InvokeAsync(Request("req-w7f-priced"));

        Assert.NotNull(priced.Cost);
        Assert.Equal(0.50m + 1.50m, priced.Cost!.Amount);
        Assert.False(priced.Cost.IsEstimated, "The figure is measured from observed tokens.");
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 7 and TASK 11: an unavailable Head is contained, and nothing is executed to find that out.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AnUnavailableHead_IsContained_WithNoExecutionReference_AndNothingInvoked()
    {
        var path = GovernedPath.Compose(TwoRoutes());

        // A snapshot holding no providers is the estate saying nothing - not by configuration and not
        // by a probe. The projection reads that as Unknown, which is not servable.
        path.Health.Publish(new AiHealthSnapshot
        {
            TakenAt = DateTimeOffset.UnixEpoch,
            Source = "w7f-test-no-probe-has-run",
        });

        var response = await GatewayFor(path).InvokeAsync(Request("req-w7f-unavailable"));

        Assert.Equal(AiExecutionStatus.Degraded, response.Status);
        Assert.True(response.IsDegraded);
        Assert.Equal(AiFailureCategory.AiUnavailable, response.Failure!.Category);
        Assert.True(response.Failure.Retryable);

        // Absent, because nothing ran. An execution identity for work that never happened would
        // resolve, under authority, to an audit record that does not exist.
        Assert.Null(response.Execution);
        Assert.Null(response.AuditReference);
        Assert.Null(response.Output);

        // The load-bearing assertion: no provider was reached. Not "the response says so" - the
        // recording seam was never called, and the ledger has nothing in it.
        Assert.Equal(0, path.Model.Count);
        Assert.Empty(path.Ledger.Entries());

        // TASK 7: the failure is provider-neutral. Neither route is named anywhere in the answer.
        var rendered = Render(response);

        Assert.DoesNotContain(PrimaryProvider, rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(AlternateProvider, rendered, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ACallerThatAskedToFail_IsFailedRatherThanLabelledDegraded()
    {
        var path = GovernedPath.Compose(TwoRoutes());
        path.Health.Publish(new AiHealthSnapshot
        {
            TakenAt = DateTimeOffset.UnixEpoch,
            Source = "w7f-test-no-probe-has-run",
        });

        var gateway = GatewayFor(path);

        // AiDegradationPreference.Fail: there is no deterministic path and the caller has said so.
        var request = Request("req-w7f-fail-fast") with
        {
            Execution = new AiExecutionPolicy
            {
                Quality = AiQualityRequirement.Complete,
                OnDegradation = AiDegradationPreference.Fail,
            },
        };

        var response = await gateway.InvokeAsync(request);

        Assert.Equal(AiExecutionStatus.Failed, response.Status);

        // Not degraded: a caller that asked to fail has not taken a deterministic path, it has been
        // refused. Reporting the degraded label here would be the estate deciding something the caller
        // already said.
        Assert.False(response.IsDegraded);

        // The same typed failure, so a caller branches on one category rather than two.
        Assert.Equal(AiFailureCategory.AiUnavailable, response.Failure!.Category);
        Assert.Null(response.Execution);

        // NON-VACUITY: the identical estate under the default preference answers Degraded, so the
        // difference above is the caller's policy being read rather than a constant.
        var defaulted = await gateway.InvokeAsync(Request("req-w7f-degraded"));

        Assert.Equal(AiExecutionStatus.Degraded, defaulted.Status);
        Assert.True(defaulted.IsDegraded);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 11: a refused execution carries the category that refused it.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task ABlockedExecution_CarriesATypedFailureFromTheGateThatRefusedIt()
    {
        // The capability is declared prohibited, so governance refuses before any route is selected.
        var path = GovernedPath.Compose(TwoRoutes() with
        {
            Dependencies = [GovernedPath.Prohibited(AiCapabilities.ChatComplete)],
        });

        var response = await GatewayFor(path).InvokeAsync(Request("req-w7f-blocked"));

        Assert.Equal(AiExecutionStatus.Blocked, response.Status);
        Assert.NotNull(response.Failure);
        Assert.Equal(AiFailureCategory.PolicyBlocked, response.Failure!.Category);
        Assert.False(response.PolicyDecision!.Allowed);
        Assert.NotNull(response.PolicyDecision.Reason);
        Assert.True(path.Model.Count == 0, "A refusal is not an invocation.");

        // The execution happened and was refused, so the caller still holds a resolvable reference to
        // it. This is the distinction the degraded path exists to preserve: a refusal is a record, an
        // unavailable Head is nothing at all.
        Assert.NotNull(response.Execution);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 11 and TASK 15: no exception from below the gateway crosses it.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AVendorException_DoesNotCrossTheGateway_AndItsTextIsNotReproduced()
    {
        // The shape of what a provider SDK raises: a type named after the vendor, carrying an endpoint
        // and a model name in its message. Every one of those facts must stop here.
        var execution = new ThrowingExecution(new VendorSdkException(
            "openai request to https://api.openai.com/v1/chat/completions for model 'gpt-4o' failed: 429"));

        var gateway = GatewayFor(execution);
        var response = await gateway.InvokeAsync(Request("req-w7f-vendor"));

        Assert.Equal(1, execution.Calls);
        Assert.Equal(AiExecutionStatus.Failed, response.Status);
        Assert.NotNull(response.Failure);

        // A neutral category and a neutral code, both written by the gateway.
        Assert.Equal(AiFailureCategory.AiUnavailable, response.Failure!.Category);
        Assert.Equal("gateway_execution_faulted", response.Failure.Code);

        // The message is caller-safe and says nothing the vendor said. Asserted over the rendered
        // response, so a member added later that carried the exception would fail here.
        var rendered = Render(response);

        Assert.DoesNotContain("openai", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("gpt-4o", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("api.openai.com", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("429", rendered, StringComparison.Ordinal);
        Assert.DoesNotContain(nameof(VendorSdkException), rendered, StringComparison.Ordinal);

        // ...and the exception did not merely get swallowed into a success.
        Assert.Null(response.Execution);
    }

    [Fact]
    public async Task ATypedAiFailure_IsReProjected_RatherThanReThrown()
    {
        // The same boundary, reached by the estate's own exception type rather than a vendor's. The
        // caller receives a response like every other failure, so the shape of the answer does not
        // depend on which layer noticed first.
        var execution = new ThrowingExecution(new AiCapabilityException(
            AiFailureCategory.ProviderUnavailable,
            "provider_health_unusable",
            "No route this execution was permitted to use is currently serving.",
            "corr-w7f-typed"));

        var response = await GatewayFor(execution).InvokeAsync(Request("req-w7f-typed"));

        Assert.Equal(AiExecutionStatus.Failed, response.Status);

        // The typed failure crosses unchanged: it was already provider-neutral when it was raised.
        Assert.Equal(AiFailureCategory.ProviderUnavailable, response.Failure!.Category);
        Assert.Equal("provider_health_unusable", response.Failure.Code);
        Assert.Equal("corr-w7f-typed", response.Failure.CorrelationId);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 1 and TASK 13: the caller's tool declaration is an offer, never an authority.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task ACallerCannotLowerTheToolCeiling_AndCannotTurnOffWriteApproval()
    {
        // The registry classifies the tool as writing. The caller declares it may cause no side effect
        // at all and that no approval is required - two statements that would each, if honoured, grant
        // the caller something the estate has not agreed to.
        var path = GovernedPath.Compose(TwoRoutes() with
        {
            Tools = [GovernedPath.Tool("repo.write", sideEffect: "Write", requiresHumanApproval: false)],
            OfferedToolIds = ["repo.write"],
        });

        var gateway = GatewayFor(path, new FakeToolCatalog(
            GovernedPath.Descriptor("repo.write", SideEffectClass.Write)));

        // The requester is permitted to cause side effects, so the permission-scope gate is not the
        // binding constraint. The claim under test is about the APPROVAL gate and about the ceiling the
        // registry states, and a requester that could not cause side effects at all would refuse for a
        // reason this test did not name.
        var request = Request("req-w7f-ceiling") with
        {
            Requester = GovernedPath.Requester(
                mayCauseSideEffects: true,
                requiresHumanApprovalForSideEffects: false),
            Tools = new ToolPermissionProfile
            {
                AllowedToolIds = ["repo.write"],
                MaxSideEffect = ToolSideEffectClass.None,
                RequireApprovalForWrites = false,
            },
        };

        var response = await gateway.InvokeAsync(request);

        // The registry's ceiling applies and the approval gate fires, so nothing runs. The caller's
        // declaration lowered nothing: neither the ceiling it typed nor the approval it declined.
        Assert.Equal(AiExecutionStatus.PendingHumanDecision, response.Status);
        Assert.Equal(AiFailureCategory.HumanDecisionRequired, response.Failure!.Category);
        Assert.True(response.Failure.RequiresHumanAction);
        Assert.Equal(0, path.Model.Count);

        // NON-VACUITY: the same caller offering nothing gets a normal answer from the same estate, so
        // the refusal above is the write ceiling and not an estate that refuses everything.
        var withoutTools = await gateway.InvokeAsync(Request("req-w7f-no-tools"));

        Assert.Equal(AiExecutionStatus.Succeeded, withoutTools.Status);
    }

    [Fact]
    public async Task AToolThePlatformCatalogueDoesNotList_IsNeverOffered()
    {
        var options = TwoRoutes() with
        {
            Tools = [GovernedPath.Tool("repo.read", sideEffect: "Read")],
            OfferedToolIds = ["repo.read"],
        };

        var request = Request("req-w7f-catalogue") with
        {
            Tools = new ToolPermissionProfile { AllowedToolIds = ["repo.read"] },
        };

        // The catalogue does not list the tool, so it is dropped from the offer rather than passed on.
        var unlisted = GovernedPath.Compose(options);
        var dropped = await GatewayFor(unlisted, new FakeToolCatalog()).InvokeAsync(request);

        Assert.Equal(AiExecutionStatus.Succeeded, dropped.Status);
        Assert.Empty(unlisted.Model.Invocations[0].Tools);

        // NON-VACUITY: the same estate with a catalogue that does list it offers exactly that tool, so
        // the empty list above is the catalogue intersection and not a fixture that offers nothing.
        var listed = GovernedPath.Compose(options);
        var offered = await GatewayFor(listed, new FakeToolCatalog(GovernedPath.Descriptor("repo.read")))
            .InvokeAsync(request);

        Assert.Equal(AiExecutionStatus.Succeeded, offered.Status);
        Assert.Equal("repo.read", Assert.Single(listed.Model.Invocations[0].Tools).ToolId);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 2 and TASK 12: a replay is a second execution, and the first one survives it.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AReplayOfTheSameRequest_MintsADistinctExecution_AndKeepsTheFirstAuditRecord()
    {
        var path = GovernedPath.Compose(TwoRoutes());
        var gateway = GatewayFor(path);
        var request = Request("req-w7f-replay");

        var first = await gateway.InvokeAsync(request);
        var second = await gateway.InvokeAsync(request);

        // The request identifier is echoed unchanged on both: it is the caller's correlation identity
        // and stability across a retry is the whole point of it.
        Assert.Equal(request.RequestId, first.RequestId);
        Assert.Equal(request.RequestId, second.RequestId);

        // The execution identities differ, because the estate served the work twice.
        Assert.NotEqual(first.Execution!.ExecutionId, second.Execution!.ExecutionId);
        Assert.NotEqual(first.AuditReference, second.AuditReference);

        // The identity the estate minted is the one this fixture handed out, so the assertion is about
        // what was written rather than about two generated values differing.
        Assert.Equal("exec-0001", first.Execution.ExecutionId);
        Assert.Equal("exec-0002", second.Execution.ExecutionId);

        // Neither overwrote the other: two ledger entries, keyed by two execution identities.
        var entries = path.Ledger.Entries();

        Assert.Equal(2, entries.Count);
        Assert.Equal(2, entries.Select(entry => entry.ExecutionId).Distinct(StringComparer.Ordinal).Count());

        // ...and both are resolvable afterwards, which is the property the collapsed identity destroyed.
        Assert.NotNull(path.Operations.Execution(first.Execution.ExecutionId));
        Assert.NotNull(path.Operations.Execution(second.Execution.ExecutionId));
    }

    [Fact]
    public async Task TheMeteringKey_IsNotTheCallersRequestIdentifier()
    {
        var path = GovernedPath.Compose(TwoRoutes());
        var invocationIds = new CountingAiExecutionIdSource();
        var gateway = GatewayFor(path, new FakeToolCatalog(), invocationIds);

        await gateway.InvokeAsync(Request("req-w7f-meter"));
        await gateway.InvokeAsync(Request("req-w7f-meter"));

        // Two invocations, two invocation identities. Reusing the request identifier here would
        // reproduce, in the Platform meter, the defect W7F corrected in the audit store.
        Assert.Equal(2, invocationIds.Issued);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 1: the capability listing carries governance facts and no routes.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task TheCapabilityListing_NamesNoModelVendorOrEndpoint()
    {
        var path = GovernedPath.Compose(TwoRoutes());
        var capabilities = await GatewayFor(path).ListCapabilitiesAsync();

        Assert.NotEmpty(capabilities);

        // The bootstrap register's identifiers, served as they are. The type has no member for a model
        // or a vendor, which is asserted structurally in the architecture suite; what is asserted here
        // is that the gateway serves the register rather than a filtered or rebuilt copy of it.
        Assert.Contains(capabilities, entry => entry.Capability.Value == AiCapabilities.CodeReview);
        Assert.Contains(capabilities, entry => entry.Capability.Value == AiCapabilities.ChatComplete);

        var rendered = string.Join("|", capabilities.Select(entry => entry.ToString()));

        Assert.DoesNotContain(PrimaryModel, rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(PrimaryProvider, rendered, StringComparison.OrdinalIgnoreCase);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 3: citations are resolved against what was admitted, not against what the model wrote.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task ACitation_IsResolvedOnlyAgainstTheContextThatWasAdmitted()
    {
        var context = GovernedPath.Context(
            GovernedPath.Item("doc-1", "The architecture record.", DataClassification.Public),
            GovernedPath.Item("doc-2", "An unrelated note.", DataClassification.Public));

        var path = GovernedPath.Compose(TwoRoutes() with
        {
            Replies = ["Grounded in [ctx:doc-1] and also in [ctx:doc-9], which was never sent."],
        });

        var response = await GatewayFor(path).InvokeAsync(
            Request("req-w7f-citations") with { Context = context });

        // One citation: the marker naming a document that was admitted. The marker naming one that was
        // not is dropped, because a citation list built from the model's own text would let it cite a
        // source it was never given.
        var citation = Assert.Single(response.Citations);

        Assert.Equal("doc-1", citation.ContextItemId);

        // NON-VACUITY: the same extractor resolves both markers when both were admitted, so the single
        // citation above is the admission filter rather than the pattern failing to match.
        var both = CitationExtractor.Extract(
            response.Output!,
            new HashSet<string>(["doc-1", "doc-9"], StringComparer.Ordinal));

        Assert.Equal(2, both.Count);
    }

    // ---------------------------------------------------------------------------------------------
    // A malformed request is a caller defect, and is reported as one.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AMalformedRequest_Throws_RatherThanReportingAnAiFailure()
    {
        var path = GovernedPath.Compose(TwoRoutes());
        var gateway = GatewayFor(path);
        var request = Request("req-w7f-malformed");

        await Assert.ThrowsAsync<ArgumentNullException>(() => gateway.InvokeAsync(null!));
        await Assert.ThrowsAsync<ArgumentException>(() => gateway.InvokeAsync(request with { RequestId = " " }));
        await Assert.ThrowsAsync<ArgumentException>(() => gateway.InvokeAsync(request with { Purpose = "" }));
        await Assert.ThrowsAsync<ArgumentException>(() => gateway.InvokeAsync(request with { IdempotencyKey = "" }));

        await Assert.ThrowsAsync<ArgumentException>(() => gateway.InvokeAsync(request with
        {
            Requester = Requester() with { PrincipalId = "" },
        }));

        // A caller defect is not an AI failure, and nothing was executed while finding that out.
        Assert.Equal(0, path.Model.Count);
    }

    // ---------------------------------------------------------------------------------------------
    // Composition.
    // ---------------------------------------------------------------------------------------------

    /// <summary>A gateway over a composed governed path, with the estate's own collaborators.</summary>
    /// <remarks>
    /// The execution path, the operations read model and the health snapshot are the harness's real
    /// objects, so a test composed here is a statement about the estate rather than about a stand-in for
    /// it. Only the two things that leave the process are replaced: the tool catalogue, which is a
    /// Platform port this repository does not implement, and the invocation-identity source, which is a
    /// known sequence so a test can name what the meter was given.
    /// </remarks>
    private static AiCapabilityGateway GatewayFor(
        GovernedPath path,
        IToolCatalog? tools = null,
        IAiExecutionIdSource? invocationIds = null)
        => Compose(
            path.Execution,
            path.Operations,
            path.Health,
            tools ?? new FakeToolCatalog(),
            invocationIds ?? new CountingAiExecutionIdSource());

    /// <summary>A gateway over an execution path that is not the composed one.</summary>
    /// <remarks>
    /// Used by the two tests that reach the boundary with an execution that throws, where there is no
    /// composed estate to read from and nothing ran to record. The operations surface is a real answer
    /// rather than a mock: an empty operations store is a legitimate state, and the gateway reads it as
    /// "no cost and no usage were recorded", which is what it would report for an execution the recorder
    /// never saw.
    /// </remarks>
    private static AiCapabilityGateway GatewayFor(IGovernedTurnExecution execution)
        => Compose(
            execution,
            new EmptyOperationsReadModel(),
            new InMemoryAiHealthSnapshotStore(HealthySnapshot()),
            new FakeToolCatalog(),
            new CountingAiExecutionIdSource());

    private static AiCapabilityGateway Compose(
        IGovernedTurnExecution execution,
        IAiOperationsReadModel operations,
        IAiHealthSnapshotStore health,
        IToolCatalog tools,
        IAiExecutionIdSource invocationIds)
    {
        var capabilities = AiCapabilityRegister.Bootstrap();

        return new AiCapabilityGateway(
            execution,
            new AiGatewayAvailabilityProjection(health, capabilities, TimeProvider.System),
            capabilities,
            operations,
            tools,
            invocationIds,
            TimeProvider.System);
    }

    /// <summary>A snapshot declaring one healthy provider, so availability is not the subject.</summary>
    /// <remarks>
    /// Deliberately a populated snapshot rather than an empty one: the tests that build a gateway over a
    /// throwing execution are about what crosses the boundary from below it, and an estate that read as
    /// unavailable would refuse before reaching the execution under test at all.
    /// </remarks>
    private static AiHealthSnapshot HealthySnapshot() => new()
    {
        TakenAt = DateTimeOffset.UnixEpoch,
        Source = "w7f-test",
        Providers = new Dictionary<string, AiModelHealthState>(StringComparer.Ordinal)
        {
            ["prov-w7f"] = AiModelHealthState.Available,
        },
    };

    /// <summary>Everything the caller-facing response states, as one string.</summary>
    /// <remarks>
    /// A render rather than a field-by-field scan, so that a member added to the response later is
    /// covered by every disclosure assertion in this file without anyone remembering to add it. The
    /// record's own <c>ToString</c> prints every member and recurses into the nested records, which is
    /// the surface a leaked provider or model name would travel over.
    /// </remarks>
    private static string Render(AiCapabilityResponse response) => response.ToString();

    /// <summary>A provider SDK's exception, in the shape the boundary exists to contain.</summary>
    private sealed class VendorSdkException : Exception
    {
        public VendorSdkException(string message)
            : base(message)
        {
        }
    }

    /// <summary>An execution path that fails before producing an outcome.</summary>
    private sealed class ThrowingExecution : IGovernedTurnExecution
    {
        private readonly Exception _thrown;

        public ThrowingExecution(Exception thrown) => _thrown = thrown;

        /// <summary>How many times this path was reached, so "it ran once" is a count.</summary>
        public int Calls { get; private set; }

        public Task<GovernedTurnOutcome> ExecuteAsync(GovernedTurnRequest request, CancellationToken ct = default)
        {
            Calls++;

            throw _thrown;
        }
    }

    /// <summary>The tools the Platform catalogue lists, as a fixed set.</summary>
    private sealed class FakeToolCatalog : IToolCatalog
    {
        private readonly IReadOnlyList<ToolDescriptor> _tools;

        public FakeToolCatalog(params ToolDescriptor[] tools) => _tools = tools;

        public Task<IReadOnlyList<ToolDescriptor>> ListAsync(CancellationToken ct = default)
            => Task.FromResult(_tools);
    }

    /// <summary>An operations read surface with nothing in it.</summary>
    private sealed class EmptyOperationsReadModel : IAiOperationsReadModel
    {
        public AiExecutionOperationsView? Execution(string executionId) => null;

        public IReadOnlyList<AiExecutionOperationsView> Executions(AiOperationsQuery query) => [];

        public AiOperationsSummary Summarize(AiOperationsQuery query, AiUsageGroupBy groupBy) => new()
        {
            GroupBy = groupBy,
        };
    }
}
