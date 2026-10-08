using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;
using Nexus.Intelligence.Contracts;
using Xunit;

namespace Nexus.Intelligence.Tests.Gateway;

// W7F TASK 1, TASK 3, TASK 14 and TASK 15: the published contract, exercised as JSON rather than as
// objects.
//
// WHY THIS FILE EXISTS. Every other test in this suite builds a contract in memory and asserts on the
// object. That covers the contract's shape but not its wire form, and the two are not the same thing:
// the gateway's invoke route binds AiCapabilityRequest straight from the request body, so a type the
// serialiser can write but not read is a gateway that answers 400 to every caller while every
// in-memory test still passes. That is the exact defect this file was written to catch, and it caught
// it: CapabilityId held a private constructor and System.Text.Json refused to deserialise it, so
// POST /invoke could not bind its own body.
//
// The options below are deliberately not a test convenience. They mirror
// Program.cs's ConfigureHttpJsonOptions call, because a test that round-trips with different options
// than the server uses proves something about the test.
public sealed class W7fGatewayWireTests
{
    /// <summary>The serialiser configuration the API itself binds request bodies with.</summary>
    private static readonly JsonSerializerOptions ApiOptions = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter() },
    };

    // ---------------------------------------------------------------------------------------------
    // TASK 1: the request a consumer sends is the request the Head can read.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ACapabilityRequest_SurvivesTheWire_AndCarriesNoRoute()
    {
        var sent = Request("req-w7f-wire-request");

        var received = RoundTrip(sent);

        Assert.True(
            received.RequestId == sent.RequestId,
            $"the request id must survive the wire, got '{received.RequestId}'");
        Assert.True(
            received.Capability == sent.Capability,
            $"the capability must survive the wire, got '{received.Capability}'");
        Assert.True(
            received.Capability.Value == "code.review",
            $"the capability must arrive as the identifier the caller sent, got '{received.Capability.Value}'");
        Assert.True(
            received.Requester.Head == CallingHead.Forge,
            $"the calling Head must survive the wire, got '{received.Requester.Head}'");
        Assert.True(
            received.Classification == DataClassification.Internal,
            $"the classification must survive the wire, got '{received.Classification}'");
        Assert.True(
            received.IdempotencyKey == sent.IdempotencyKey,
            "the idempotency key must survive the wire or replay protection is lost in transit");

        // TASK 1 again, asserted on the wire form rather than on the type: a caller cannot name a
        // route because the bytes it would have to write do not exist in the contract.
        var json = JsonSerializer.Serialize(sent, ApiOptions);

        foreach (var forbidden in new[] { "provider", "model", "vendor", "endpoint", "apiKey", "credential", "secret" })
        {
            Assert.True(
                !json.Contains(forbidden, StringComparison.OrdinalIgnoreCase),
                $"the capability request wire form must not carry '{forbidden}' (json: {json})");
        }
    }

    [Fact]
    public void ACapabilityIdentifier_IsAPlainJsonString_NotAnObject()
    {
        // The wire shape of CapabilityId is a decision, not an accident, and the decision is "a
        // string". Consumers in three repositories read this, so it is asserted here: an object form
        // ({"value":"code.review"}) would be a breaking change to every one of them, and it is the
        // shape a naive converter would have produced.
        var json = JsonSerializer.Serialize(Request("req-w7f-wire-shape"), ApiOptions);

        Assert.True(
            json.Contains("\"capability\":\"code.review\"", StringComparison.Ordinal),
            $"a capability must serialise as a plain string, got: {json}");
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 3: the response a consumer receives is a response it can read.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ACapabilityResponse_SurvivesTheWire_WithItsEvidenceIntact()
    {
        var sent = new AiCapabilityResponse
        {
            RequestId = "req-w7f-wire-response",
            Capability = CapabilityId.Parse("code.review"),
            CorrelationId = "correlation-1",
            Status = AiExecutionStatus.Succeeded,
            Output = "reviewed",
            UsedFallback = true,
            IsDegraded = false,
            Execution = new AiExecutionReference { ExecutionId = "exec-1" },
            AuditReference = "audit-1",
            Elapsed = TimeSpan.FromMilliseconds(250),
        };

        var received = RoundTrip(sent);

        Assert.True(received.RequestId == sent.RequestId, "the request id must survive the wire");
        Assert.True(received.Capability == sent.Capability, "the capability must survive the wire");
        Assert.True(
            received.Status == AiExecutionStatus.Succeeded,
            $"the status must survive the wire, got '{received.Status}'");
        Assert.True(received.Output == "reviewed", "the output must survive the wire");
        Assert.True(received.UsedFallback, "the fallback flag must survive the wire");
        Assert.True(
            received.Execution is not null && received.Execution.ExecutionId == "exec-1",
            "the execution reference must survive the wire; it is how a caller cites this execution");
        Assert.True(
            received.Elapsed == sent.Elapsed,
            $"the elapsed time must survive the wire, got '{received.Elapsed}'");
    }

    [Fact]
    public void ACapabilityResponse_CarriesATypedFailure_AcrossTheWire()
    {
        // TASK 11: the failure a consumer reads is the contract's own category, never a vendor's.
        var sent = new AiCapabilityResponse
        {
            RequestId = "req-w7f-wire-failure",
            Capability = CapabilityId.Parse("code.review"),
            CorrelationId = "correlation-1",
            Status = AiExecutionStatus.Failed,
            IsDegraded = true,
            Failure = AiFailure.From(
                AiFailureCategory.PolicyBlocked,
                "policy_blocked",
                "Governance refused this request.",
                "correlation-1"),
        };

        var received = RoundTrip(sent);

        Assert.True(received.Failure is not null, "the failure must survive the wire");
        Assert.True(
            received.Failure!.Category == AiFailureCategory.PolicyBlocked,
            $"the failure category must survive the wire, got '{received.Failure.Category}'");
        Assert.True(
            received.Failure.Retryable == sent.Failure!.Retryable,
            "the category's retry semantics must be reconstructed identically on the far side");
        Assert.True(
            received.Execution is null,
            "a refused request ran nothing, and that absence must survive the wire too");
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 6 and TASK 7: the discovery surfaces are readable by the clients that consume them.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ACapabilityRegistration_SurvivesTheWire()
    {
        // ListCapabilitiesAsync deserialises this. It is the same CapabilityId hazard as the request,
        // in the one method that has no failure channel to report a read error through.
        var sent = new List<AiCapabilityRegistration>
        {
            new()
            {
                Capability = CapabilityId.Parse("architecture.review"),
                Description = "Reviews a proposed architecture.",
                DependencyClass = AiDependencyClass.AiEnhanced,
                Owner = "AI Head",
                DependencyRationale = "Advice; the deterministic gate owns the mutation.",
            },
        };

        var json = JsonSerializer.Serialize<IReadOnlyList<AiCapabilityRegistration>>(sent, ApiOptions);
        var received = JsonSerializer.Deserialize<IReadOnlyList<AiCapabilityRegistration>>(json, ApiOptions);

        Assert.True(received is not null, "the capability register must be readable by a consumer");
        Assert.True(
            received!.Count == 1,
            $"the register must survive the wire intact, got {received.Count} entries");
        Assert.True(
            received[0].Capability == sent[0].Capability,
            $"the capability must survive the wire, got '{received[0].Capability}'");
        Assert.True(
            received[0].DependencyClass == AiDependencyClass.AiEnhanced,
            $"the dependency class must survive the wire, got '{received[0].DependencyClass}'");
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    private static T RoundTrip<T>(T value)
    {
        var json = JsonSerializer.Serialize(value, ApiOptions);
        var received = JsonSerializer.Deserialize<T>(json, ApiOptions);

        Assert.True(received is not null, $"'{typeof(T).Name}' must be deserialisable from its own JSON");

        return received!;
    }

    private static AiCapabilityRequest Request(string requestId) => new()
    {
        RequestId = requestId,
        Capability = CapabilityId.Parse("code.review"),
        Purpose = "review the change before merge",
        Requester = new AiRequesterIdentity
        {
            Head = CallingHead.Forge,
            ProductId = "forge",
            PrincipalId = "forge-service",
            IsServicePrincipal = true,
            PermissionScope = new AiPermissionScope { Permissions = ["ai.code.review"] },
        },
        Input = new TurnInput(TurnInputKind.UserMessage, "review this", []),
        Classification = DataClassification.Internal,
        CorrelationId = "correlation-1",
        IdempotencyKey = "idem-1",
    };
}
