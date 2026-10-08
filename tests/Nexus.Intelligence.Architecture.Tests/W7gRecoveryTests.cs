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
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;
using Nexus.Platform.Core.Models;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7G TASK 6: recovery after an AI outage.
//
// WHAT THIS SUITE IS FOR. Task 5 proves the estate SURVIVES an outage. That is half the property, and it
// is the half a Product notices first. This suite proves the other half: that the outage does not LATCH.
// An estate that answers every request correctly once its provider returns, and an estate that has
// quietly poisoned a cache, a circuit or a sticky routing decision with the failure, are
// indistinguishable under Task 5 — both "do not crash". They are very different in production, because
// the second one stays broken after the cause is fixed, and nothing in a crash-free observation says so.
//
// THE FAILURE MODE THIS EXISTS TO CATCH. Two of them, both classic and both silent:
//
//   1. A failed route is recorded as unhealthy and never re-probed, so the estate stays degraded after
//      the provider is well again. Nothing errors; throughput is simply gone.
//   2. The caller's request is cached by idempotency key while it fails, so the retry that would
//      otherwise succeed is answered from the recorded failure instead of being re-executed. This one
//      is worse, because the retry looks like it worked.
//
// THE SEAM IS THE SAME ONE W7gProviderSwapTests FAKES, and for the same reason: `INamedModelGateway` is
// the interface a provider package implements, so the estate's REAL `ModelStep` and REAL
// `RoutingModelGateway` run, and the provider is resolved from configuration the governed router chose.
// The only difference here is that the fake provider can be switched between failing and answering.
//
// WHAT IS DELIBERATELY NOT ASSERTED. No timing, no retry count and no backoff. A recovery test that
// asserted "recovers within N milliseconds" would fail on a loaded build agent while telling nobody
// anything about correctness; the property under test is "the next request after the provider returns is
// served", which is a statement about state and not about speed.
public sealed class W7gRecoveryTests
{
    /// <summary>The vendor token of the one provider implementation this suite registers.</summary>
    private const string Vendor = "recovery";

    /// <summary>The model this suite routes to. The prefix before ':' is the vendor token.</summary>
    private const string Model = Vendor + ":chat-1";

    /// <summary>The provider registration this suite declares.</summary>
    /// <remarks>
    /// Named <c>ProviderRegistration</c> rather than <c>Provider</c> deliberately: the nested
    /// <see cref="Estate"/> type carries an instance member of that name, and an outer constant sharing
    /// it would be shadowed inside the estate — which compiles into a confusing instance-reference error
    /// in a static method rather than into the naming problem it actually is.
    /// </remarks>
    private const string ProviderRegistration = "prov-recovery";

    /// <summary>
    /// The text a FAILING provider returns in <c>ModelInvocationResult.Error</c>.
    /// </summary>
    /// <remarks>
    /// It is a sentinel with an unmistakable shape, and its presence in a caller-facing field is the
    /// failure it names. A real adapter fills this field with a vendor exception's message
    /// (`OpenAIModelGateway.cs` assigns <c>ex.Message</c>), so a sentinel here stands in for exactly the
    /// string that must never reach a consumer. Task 7 closed that path; this is a second, independent
    /// guard on the same defect, taken from the recovery direction rather than the failover one.
    /// </remarks>
    private const string ProviderMarkerText =
        "vndr-internal-9f2c: provider refused the request (upstream 429, region eu-west-2, req 8ac1)";

    /// <summary>The caller's request identifier. Held constant so identity preservation is testable.</summary>
    private const string RequestId = "req-w7g-recovery";

    /// <summary>The capability both the request and the registry declare.</summary>
    private const string Capability = "chat.complete";

    /// <summary>
    /// The instant every clock in this suite starts from.
    /// </summary>
    /// <remarks>
    /// Fixed rather than <c>UtcNow</c>, because every timing assertion in this suite is about a
    /// <em>difference</em> — how long after a circuit opened its cooldown elapses. An assertion written
    /// against a wall clock would pass or fail according to how long the machine took to run the
    /// preceding lines, which on a busier machine is the difference between a green suite and a flaky
    /// one. The origin's absolute value is arbitrary and deliberately not near any real date.
    /// </remarks>
    private static readonly DateTimeOffset Origin = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    /// <summary>
    /// The cooldown the suite waits out, which is the shipped policy's own value.
    /// </summary>
    /// <remarks>
    /// Read from <see cref="AiCircuitPolicy.Default"/> rather than written as a second literal, so a
    /// test that waits out a different duration from the one the estate enforces cannot compile into a
    /// green suite. It is <em>not</em> used to configure the estate: the estate is composed with the
    /// shipped policy throughout, and this only says how far to move the clock.
    /// </remarks>
    private static readonly TimeSpan RecoveryCooldown = AiCircuitPolicy.Default.Cooldown;

    /// <summary>
    /// Drives the estate to the observed record that opens a circuit, and asserts it got there.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Five calls alternating failure and success, so the record is <c>F S F S F</c>: two successes in
    /// five attempts, an observed rate of 0.4 against a floor of 0.5, on a sample that meets the
    /// configured minimum. Deliberately not three <em>consecutive</em> failures, which would open the
    /// circuit on the separate consecutive-failure condition and would prove the wrong one of the two
    /// — and the rate condition is the one the Human Owner's decision is about, because it is the one
    /// that cannot clear itself.
    /// </para>
    /// <para>
    /// Shared by the tests below rather than repeated, so that the record under test is one thing
    /// written one way. The assertion at the end is the reason it is safe to share: if this setup ever
    /// stops producing an open circuit, every test that depends on it fails here, at the setup, rather
    /// than somewhere downstream where the cause would be obscure.
    /// </para>
    /// </remarks>
    private static async Task ReachTheRateFloorAsync(Estate estate)
    {
        estate.Provider.Healthy = false;
        await estate.PostAsync(idempotencyKey: "idem-gate-1");

        estate.Provider.Healthy = true;
        await estate.PostAsync(idempotencyKey: "idem-gate-2");

        estate.Provider.Healthy = false;
        await estate.PostAsync(idempotencyKey: "idem-gate-3");

        estate.Provider.Healthy = true;
        await estate.PostAsync(idempotencyKey: "idem-gate-4");

        estate.Provider.Healthy = false;
        await estate.PostAsync(idempotencyKey: "idem-gate-5");

        Assert.True(
            estate.Provider.Count == 5,
            $"the five gate-filling calls must have reached the provider, got {estate.Provider.Count}");
    }

    // ---------------------------------------------------------------------------------------------
    // The recovery property.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AnOutageIsNotLatched_TheNextRequestAfterTheProviderReturnsIsServed()
    {
        await using var estate = await Estate.StartAsync();

        estate.Provider.Healthy = false;

        var (_, duringOutage, _) = await estate.PostAsync(idempotencyKey: "idem-1");

        // The outage is real and the estate reported it as a failure, not as a success with no output.
        Assert.True(
            duringOutage.Status != AiExecutionStatus.Succeeded,
            "a request served by a failing provider must not be reported as succeeded");

        Assert.True(
            duringOutage.Failure is not null,
            "a non-success execution must carry a typed failure");

        // THE RECOVERY. The provider is well again; nothing else about the estate changed.
        estate.Provider.Healthy = true;

        var (_, afterRecovery, _) = await estate.PostAsync(idempotencyKey: "idem-2");

        Assert.True(
            afterRecovery.Status == AiExecutionStatus.Succeeded,
            $"the estate must serve the next request once the provider returns, got "
                + $"{afterRecovery.Status}: {afterRecovery.Failure?.Code} — {afterRecovery.Failure?.Message}");

        Assert.True(
            afterRecovery.Failure is null,
            "a succeeded execution must carry no failure");

        // NON-VACUITY. If the estate had latched, it would either have refused the second request
        // without calling the provider, or answered it from a recorded failure. Reaching the provider a
        // second time is what proves the request was re-executed rather than replayed.
        Assert.True(
            estate.Provider.Count == 2,
            $"the provider implementation must have been reached twice — once failing, once answering — "
                + $"got {estate.Provider.Count}");
    }

    [Fact]
    public async Task AnOutageDoesNotAccumulate_WhileTheGateStillPermitsTheRoute()
    {
        await using var estate = await Estate.StartAsync();

        // Two outage/recovery pairs, which is as far as this test goes before the observed rate risks
        // reaching the boundary the recovery tests below drive deliberately. Within it, the estate must
        // alternate: `F S F S` is four attempts with two successes, an observed rate of exactly 0.5,
        // which is not below the 0.5 floor, so the route is still ordinary capacity.
        var observed = new List<AiExecutionStatus>();

        for (var i = 0; i < 2; i++)
        {
            estate.Provider.Healthy = false;
            observed.Add((await estate.PostAsync(idempotencyKey: $"idem-outage-{i}")).Response.Status);

            estate.Provider.Healthy = true;
            observed.Add((await estate.PostAsync(idempotencyKey: $"idem-recovery-{i}")).Response.Status);
        }

        Assert.True(
            observed.SequenceEqual(
                [AiExecutionStatus.Failed, AiExecutionStatus.Succeeded,
                 AiExecutionStatus.Failed, AiExecutionStatus.Succeeded]),
            $"the estate must alternate failure and recovery inside the gate, got "
                + string.Join(", ", observed));

        // NON-VACUITY: each of the four calls reached the provider. The two failures are the provider's
        // doing and the two successes are the provider's doing; had the estate latched, a "recovery"
        // would have been reported without the provider being called at all.
        Assert.True(
            estate.Provider.Count == 4,
            $"every call must reach the provider, including the ones that fail, got {estate.Provider.Count}");
    }

    [Fact]
    public async Task ARouteRefusedOnItsObservedRate_IsReleased_ByAConfiguredCooldown_AndASuccessfulProbe()
    {
        // WAS A CHARACTERISATION OF A DEFECT; IS NOW A PROOF OF THE REMEDIATION.
        //
        // W7G found that a route refused for its observed rate was never released: the rate is computed
        // from `IAiReliabilityHistory`, whose only writer runs once per provider INVOCATION, and a
        // refused route is never invoked — so the rate could not change and the route stayed refused
        // while its provider was healthy. That test said, in its own failure message, that if it ever
        // started passing then the defect had been fixed and both it and W7G_RECOVERY.md must be
        // updated. It started passing. This is that update, and it is a replacement rather than a
        // deletion: the assertions below are strictly stronger than the ones they replace, and the
        // behaviour they pin is the one the Human Owner's decision requires.
        //
        // The estate below is composed with the SHIPPED recovery policy — the same one production
        // composes — so what is proven here is what an operator gets, not what a test configured.
        await using var estate = await Estate.StartAsync();

        // The route now carries the record that opens its circuit — five attempts, two of which
        // succeeded. Nothing below changes the provider's behaviour except where it says so.
        await ReachTheRateFloorAsync(estate);

        var attemptsThatReachedTheProvider = estate.Provider.Count;

        // ITEM 1 — repeated failures made the route ineligible. The provider is now HEALTHY and stays
        // healthy for the rest of this test; the estate refuses it anyway, on the record rather than on
        // the present.
        estate.Provider.Healthy = true;

        var (_, refused, _) = await estate.PostAsync(idempotencyKey: "idem-after-gate");

        Assert.True(
            refused.Status != AiExecutionStatus.Succeeded,
            "the route must be refused on its observed record");

        Assert.True(
            refused.Failure?.Code == "routing.no-eligible-model",
            $"the refusal must be the routing refusal, got '{refused.Failure?.Code}'");

        // ITEM 2 — an immediate retry is still refused, and the refusal still costs nothing. The
        // healthy provider is not called: the estate has decided to stop asking for a configured while,
        // and the while has not passed.
        Assert.True(
            estate.Provider.Count == attemptsThatReachedTheProvider,
            $"an immediate retry must not reach the provider, but the count moved from "
                + $"{attemptsThatReachedTheProvider} to {estate.Provider.Count}");

        var (_, refusedAgain, _) = await estate.PostAsync(idempotencyKey: "idem-after-gate-2");

        Assert.True(
            refusedAgain.Failure?.Code == "routing.no-eligible-model",
            $"the refusal must persist until the cooldown elapses, got '{refusedAgain.Failure?.Code}'");

        Assert.True(
            estate.Provider.Count == attemptsThatReachedTheProvider,
            "the second refusal must also leave the healthy provider uncalled");

        // The operator read during the refusal: refused, dated, and bounded. Everything below reads
        // this row rather than the in-process objects, so the facts asserted are facts the estate
        // publishes.
        var whileOpen = Assert.Single(await estate.ReadRoutesAsync());

        Assert.Equal(AiCircuitState.Open, whileOpen.Circuit.State);
        Assert.Equal(AiCircuitStateChangeReason.SuccessRateBelowFloor, whileOpen.Circuit.Reason);

        Assert.NotNull(whileOpen.Circuit.OpenedAt);
        Assert.NotNull(whileOpen.Circuit.CooldownElapsedAt);
        Assert.False(whileOpen.Circuit.CooldownElapsed);

        // ITEM 8, first reading — the failures that opened it are on the record, and the history is
        // reported rather than merely retained internally.
        Assert.Equal(5, whileOpen.Circuit.AttemptsObserved);
        Assert.Equal(3, whileOpen.Circuit.FailuresObserved);
        Assert.Equal(3, whileOpen.Evidence.Failures);

        // ITEM 3 — the configured cooldown passes. The clock moves and nothing else does: no
        // configuration is reloaded, no state is cleared, no process is restarted.
        estate.Clock.Advance(RecoveryCooldown);

        var afterCooldown = Assert.Single(await estate.ReadRoutesAsync());

        Assert.Equal(AiCircuitState.HalfOpen, afterCooldown.Circuit.State);
        Assert.Equal(AiCircuitStateChangeReason.CooldownElapsed, afterCooldown.Circuit.Reason);
        Assert.True(afterCooldown.Circuit.CooldownElapsed);
        Assert.True(afterCooldown.Circuit.IsProbePermitted);
        Assert.False(afterCooldown.Circuit.IsEligible);

        // ITEM 4 and ITEM 5 — the route re-enters and exactly the bounded probe is spent on it. The
        // allowance is one, so this single call is the whole of the traffic the estate will spend
        // finding out whether the provider came back.
        var (_, probed, _) = await estate.PostAsync(idempotencyKey: "idem-probe");

        Assert.Equal(1, estate.Provider.Count - attemptsThatReachedTheProvider);

        // ITEM 6 — the successful probe restored ordinary eligibility.
        Assert.Equal(AiExecutionStatus.Succeeded, probed.Status);

        var (_, served, _) = await estate.PostAsync(idempotencyKey: "idem-after-recovery");

        Assert.Equal(AiExecutionStatus.Succeeded, served.Status);

        // ITEM 8, second reading — after recovery the failures are STILL there. This is the assertion
        // that would fail if recovery had been implemented by forgetting: a route that recovered by
        // having its history cleared would report zero attempts here.
        var afterRecovery = Assert.Single(await estate.ReadRoutesAsync());

        Assert.Equal(AiCircuitState.Healthy, afterRecovery.Circuit.State);
        Assert.Equal(AiCircuitStateChangeReason.RecoveryCompleted, afterRecovery.Circuit.Reason);
        Assert.Equal(7, afterRecovery.Circuit.AttemptsObserved);
        Assert.Equal(3, afterRecovery.Circuit.FailuresObserved);
        Assert.Equal(3, afterRecovery.Evidence.Failures);
        Assert.NotNull(afterRecovery.Circuit.LastFailureAt);

        // ITEM 9 — recovery created new identities rather than reusing the ones the refusal and the
        // failed attempts carried. The caller's own RequestId is constant throughout, which is what
        // makes this a statement about the estate's identities rather than about the caller's: every
        // call below carried `RequestId`, and each was answered under a different execution.
        Assert.NotNull(refused.Execution);
        Assert.NotNull(probed.Execution);
        Assert.NotNull(served.Execution);

        Assert.NotEqual(refused.Execution!.ExecutionId, probed.Execution!.ExecutionId);
        Assert.NotEqual(probed.Execution.ExecutionId, served.Execution!.ExecutionId);
        Assert.NotEqual(refused.Execution.ExecutionId, served.Execution.ExecutionId);
    }

    /// <summary>
    /// A failed probe reopens the circuit, and the reopened circuit refuses again.
    /// </summary>
    /// <remarks>
    /// The other direction of the same mechanism, and the one that makes the model safe rather than
    /// merely permissive: probation that could not fail would be a route that came back the moment the
    /// estate asked, whatever the provider had done.
    /// </remarks>
    [Fact]
    public async Task AFailedProbe_ReopensTheCircuit_AndTheNextRetryIsRefused()
    {
        await using var estate = await Estate.StartAsync();

        await ReachTheRateFloorAsync(estate);

        var attemptsBeforeOpening = estate.Provider.Count;

        estate.Clock.Advance(RecoveryCooldown);

        // The provider is still broken when the probe is offered. The estate spends its one probe and
        // is told what it needed to know.
        var (_, probed, _) = await estate.PostAsync(idempotencyKey: "idem-probe-fails");

        Assert.True(
            probed.Status != AiExecutionStatus.Succeeded,
            "the probe ran against a broken provider, so it must not have succeeded");

        Assert.Equal(1, estate.Provider.Count - attemptsBeforeOpening);

        // ITEM 7 — the failed probe reopened the circuit, and the reopening is dated from the probe
        // rather than from the outage that preceded it. The provider has been given its chance and has
        // started a new cooldown.
        var reopened = Assert.Single(await estate.ReadRoutesAsync());

        Assert.Equal(AiCircuitState.Open, reopened.Circuit.State);
        Assert.Equal(AiCircuitStateChangeReason.ProbeFailed, reopened.Circuit.Reason);
        Assert.False(reopened.Circuit.CooldownElapsed);
        Assert.NotNull(reopened.Circuit.OpenedAt);
        Assert.True(
            reopened.Circuit.OpenedAt > Origin,
            "the reopening must be dated from the probe, not from the origin of the estate's clock");

        // The next retry is refused and costs nothing, exactly as after the first opening — the route
        // is back where it started, and the estate has not entered a loop of probing a broken provider.
        var afterReopening = estate.Provider.Count;
        var (_, refused, _) = await estate.PostAsync(idempotencyKey: "idem-after-reopen");

        Assert.True(
            refused.Failure?.Code == "routing.no-eligible-model",
            $"a retry after a failed probe must be refused, got '{refused.Failure?.Code}'");

        Assert.Equal(afterReopening, estate.Provider.Count);

        // And the failures are cumulative rather than reset: the reopening did not erase the record it
        // reopened on.
        Assert.Equal(6, reopened.Circuit.AttemptsObserved);
        Assert.Equal(4, reopened.Circuit.FailuresObserved);
    }

    /// <summary>
    /// With the recovery model switched off, the refusal is permanent — which is what makes the
    /// recovery above attributable to the model rather than to the passage of time.
    /// </summary>
    /// <remarks>
    /// <b>The control, and the reason it is not a formality.</b> Every assertion in the two tests above
    /// involves a clock moving. Without this test, a reader could not tell whether the route was
    /// released by the configured cooldown or by something else that happens on the sixth request. Here
    /// the same estate, the same five attempts and the same elapsed minute produce a refusal that does
    /// not end — so the difference between the two outcomes is the policy and nothing else.
    /// </remarks>
    [Fact]
    public async Task WithTheRecoveryModelDisabled_TheRefusalIsPermanent()
    {
        await using var estate = await Estate.StartAsync(
            AiCircuitPolicy.NotEvaluated,
            advancedBy: TimeSpan.FromDays(1));

        await ReachTheRateFloorAsync(estate);

        var attemptsBefore = estate.Provider.Count;

        estate.Provider.Healthy = true;
        estate.Clock.Advance(TimeSpan.FromHours(6));

        var (_, refused, _) = await estate.PostAsync(idempotencyKey: "idem-no-recovery");

        Assert.True(
            refused.Failure?.Code == "routing.no-eligible-model",
            $"with no recovery model the refusal must stand, got '{refused.Failure?.Code}'");

        Assert.Equal(attemptsBefore, estate.Provider.Count);

        // The refusal is reported as the measurement it is, not as a circuit: with the model off there
        // is no circuit to be open, and the refusal names the gate that actually fired. Without this
        // the difference between the two postures would only be visible in whether a later request
        // succeeded — which is a difference in outcome that leaves the cause unstated.
        Assert.NotNull(refused.Execution);

        var findings = await estate.ReadRefusalReasonsAsync(refused.Execution!.ExecutionId);

        Assert.Contains(AiRoutingRejectionReason.ReliabilityTooLow, findings);
        Assert.DoesNotContain(AiRoutingRejectionReason.CircuitOpen, findings);

        // And no circuit was opened on the route either, so the control is about the whole model and
        // not only about which gate the refusal was attributed to.
        var route = Assert.Single(await estate.ReadRoutesAsync());

        Assert.Equal(AiCircuitState.Healthy, route.Circuit.State);
        Assert.Equal(AiCircuitStateChangeReason.None, route.Circuit.Reason);
        Assert.True(route.Circuit.IsEligible);

        // The record that the reliability gate refused on is still kept, and still says what it said.
        // Switching the release valve off does not switch off the measurement.
        Assert.Equal(5, route.Evidence.Attempts);
        Assert.Equal(3, route.Evidence.Failures);
    }

    // ---------------------------------------------------------------------------------------------
    // Identity across the outage and the recovery.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task TheCallerRequestIdentity_IsEchoed_OnTheFailureAndOnTheRecovery()
    {
        await using var estate = await Estate.StartAsync();

        estate.Provider.Healthy = false;
        var (_, duringOutage, _) = await estate.PostAsync(idempotencyKey: "idem-1");

        estate.Provider.Healthy = true;
        var (_, afterRecovery, _) = await estate.PostAsync(idempotencyKey: "idem-2");

        // The caller's own identifier comes back unchanged on both, so a consumer can correlate a
        // failure with the retry that followed it without holding any state of its own.
        Assert.True(
            duringOutage.RequestId == RequestId,
            $"the failure must echo the caller's request id, got '{duringOutage.RequestId}'");

        Assert.True(
            afterRecovery.RequestId == RequestId,
            $"the recovery must echo the caller's request id, got '{afterRecovery.RequestId}'");

        Assert.True(
            duringOutage.Capability.Value == Capability,
            $"the failure must echo the requested capability, got '{duringOutage.Capability.Value}'");

        Assert.True(
            afterRecovery.Capability.Value == Capability,
            $"the recovery must echo the requested capability, got '{afterRecovery.Capability.Value}'");
    }

    [Fact]
    public async Task ARecoveredExecution_MintsItsOwnIdentity_RatherThanReusingTheFailedOne()
    {
        await using var estate = await Estate.StartAsync();

        estate.Provider.Healthy = false;
        var (_, duringOutage, _) = await estate.PostAsync(idempotencyKey: "idem-1");

        // A FAILED execution carries an execution reference, and that is correct rather than a leak.
        // `AiExecutionReference` is documented as "absent on a DEGRADED result, because nothing ran" —
        // and `AiExecutionStatus.Degraded` is a distinct member from `Failed`. Here the provider WAS
        // invoked and DID run; it returned a failure. Something ran, so there is an execution to
        // reference, and an operator resolving this handle finds the failing attempt behind it. (An
        // earlier draft of this suite asserted the reference was absent here, generalising the Degraded
        // rule to every non-success status. That claim was wrong, not the estate.)
        Assert.True(
            duringOutage.Execution is not null,
            "a failed-but-invoked execution must carry an execution reference, because something ran");

        var duringOutageExecutionId = duringOutage.Execution!.ExecutionId;

        estate.Provider.Healthy = true;
        var (_, afterRecovery, _) = await estate.PostAsync(idempotencyKey: "idem-2");

        Assert.True(
            afterRecovery.Execution is not null,
            "a successful execution must carry an execution reference");

        Assert.True(
            !string.IsNullOrWhiteSpace(afterRecovery.Execution!.ExecutionId),
            "the execution reference must carry a non-empty identifier");

        // THE CLAIM THE TEST IS NAMED FOR. The recovery is a NEW execution, not the failed one wearing a
        // success: a different attempt, a different identity. Reusing the failed execution's handle
        // would mean the retry was answered from the recorded failure while being reported as a success,
        // which is exactly how a latched estate would disguise itself.
        Assert.True(
            afterRecovery.Execution.ExecutionId != duringOutageExecutionId,
            $"the recovered execution must mint its own identity, but both carried "
                + $"'{afterRecovery.Execution.ExecutionId}'");

        // It is opaque, and this suite respects that: the assertions are about presence, non-emptiness
        // and distinctness, never about shape. `AiExecutionReference` states that its shape "is not part
        // of the contract and may change", so a test that parsed it would itself be the defect.
        Assert.True(
            afterRecovery.Failure is null,
            "the recovered execution must not carry the outage's failure forward");
    }

    // ---------------------------------------------------------------------------------------------
    // The outage stays provider-neutral. A second guard on the Task 7 boundary fix.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task TheOutageNeverCarriesTheProvidersOwnText_ToTheCaller()
    {
        await using var estate = await Estate.StartAsync();

        estate.Provider.Healthy = false;

        var (status, duringOutage, rawBody) = await estate.PostAsync(idempotencyKey: "idem-1");

        // Asserted against the RAW BYTES, not the deserialised object, because the bytes are what a
        // consumer actually receives. A leak that the contract type happens not to expose would still
        // be a leak on the wire.
        Assert.False(
            rawBody.Contains(ProviderMarkerText, StringComparison.Ordinal),
            "the provider's own error text must not appear anywhere in the response body");

        // Nor any fragment of it. A leak that reassembled itself one field at a time would pass a
        // whole-string check, so the distinctive tokens are checked individually.
        foreach (var fragment in new[] { "vndr-internal-9f2c", "eu-west-2", "8ac1", "upstream 429" })
        {
            Assert.False(
                rawBody.Contains(fragment, StringComparison.OrdinalIgnoreCase),
                $"the provider's fragment '{fragment}' must not reach the caller");
        }

        // The failure is typed rather than raw, and it names a category from the closed vocabulary.
        Assert.True(duringOutage.Failure is not null, "the outage must produce a typed failure");

        Assert.True(
            duringOutage.Failure!.Category != AiFailureCategory.Unspecified,
            "the failure must be classified, not left Unspecified");

        Assert.True(
            !string.IsNullOrWhiteSpace(duringOutage.Failure.Code),
            "the failure must carry a stable machine-readable code");

        // The estate answered on the contract rather than failing the transport. `PostAsync` asserts
        // the 200 as well; it is restated here because "the outage did not become a 500" is the claim
        // this test would otherwise leave implicit.
        Assert.True(
            status == HttpStatusCode.OK,
            $"an outage must be reported inside the contract envelope, got {(int)status}");
    }

    // ---------------------------------------------------------------------------------------------
    // Controls. Without these, every assertion above would also pass on an estate that never worked.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task Control_AnEstateWhoseProviderNeverFails_SucceedsThroughout()
    {
        await using var estate = await Estate.StartAsync();

        // The provider starts healthy and is never switched. Every call succeeds. This is the control
        // for the whole suite: it proves the estate can serve this request at all, so the failures the
        // other tests observe are attributable to the switch and to nothing else.
        for (var i = 0; i < 3; i++)
        {
            var (_, response, _) = await estate.PostAsync(idempotencyKey: $"idem-control-{i}");

            Assert.True(
                response.Status == AiExecutionStatus.Succeeded,
                $"control call {i} must succeed, got {response.Status}: {response.Failure?.Message}");
        }

        Assert.True(estate.Provider.Count == 3, $"the provider must have served all three, got {estate.Provider.Count}");
    }

    [Fact]
    public async Task Control_TheSwitchIsWhatChanged_TheProviderTextIsPresentOnItsOwnRecord()
    {
        await using var estate = await Estate.StartAsync();

        estate.Provider.Healthy = false;
        await estate.PostAsync(idempotencyKey: "idem-1");

        // The provider really did fail, and it really did say why. Without this, "the caller saw no
        // provider text" would also pass on a provider that produced no text in the first place — the
        // assertion above would be true for the wrong reason, and the boundary would look clean while
        // nothing had been tested.
        Assert.True(
            estate.Provider.LastError == ProviderMarkerText,
            "the provider must have reported its own error text, or the leak assertions prove nothing");
    }

    // ---------------------------------------------------------------------------------------------
    // The estate.
    // ---------------------------------------------------------------------------------------------

    /// <summary>A running real HTTP estate whose single provider implementation is switchable.</summary>
    private sealed class Estate : IAsyncDisposable
    {
        private WebApplication _app = null!;

        /// <summary>The HTTP client, addressed at the running server's own port.</summary>
        public required HttpClient Client { get; init; }

        /// <summary>The one provider implementation, switchable between failing and answering.</summary>
        public required SwitchableProviderGateway Provider { get; init; }

        /// <summary>The estate's clock, so a cooldown can be waited out in a test and nowhere else.</summary>
        public required ControllableTimeProvider Clock { get; init; }

        /// <summary>Boots the estate through the API's own composition root.</summary>
        /// <param name="recovery">
        /// The recovery posture to compose. Null means the shipped policy — the same one production
        /// composes — so a test that does not name it is testing what an operator would get.
        /// </param>
        /// <param name="advancedBy">
        /// How far the clock is set forward from an arbitrary origin before the estate boots. Only the
        /// <em>elapsed</em> time between the origin and a cooldown matters, so the origin is fixed and
        /// every assertion is a difference rather than a wall-clock reading.
        /// </param>
        public static async Task<Estate> StartAsync(
            AiCircuitPolicy? recovery = null,
            TimeSpan? advancedBy = null)
        {
            var builder = WebApplication.CreateSlimBuilder();

            // Bound explicitly for the reason recorded at length in W7gProviderSwapTests: the
            // configuration sources are cleared immediately below, which would take a `urls` setting
            // with it and leave the estate on the default port, colliding with every other Kestrel
            // estate in this assembly. `ConfigureKestrel` is a DI registration and survives the clear.
            builder.WebHost.ConfigureKestrel(kestrel => kestrel.Listen(IPAddress.Loopback, 0));

            builder.Configuration.Sources.Clear();
            builder.Configuration.AddJsonStream(new MemoryStream(Encoding.UTF8.GetBytes(EstateJson(recovery))));

            builder.Services.AddSingleton<IToolCatalog, EmptyToolCatalog>();
            builder.Services.AddSingleton<IToolGateway, EmptyToolGateway>();

            builder.Services.AddNexusIntelligence(builder.Configuration);

            var provider = new SwitchableProviderGateway(Vendor);
            builder.Services.AddSingleton<INamedModelGateway>(provider);

            // The clock is registered AFTER the composition root, and that ordering is load-bearing:
            // the extension registers TimeProvider through TryAddSingleton, so a clock registered first
            // would be the one the extension found already present and the one everything resolved —
            // and this registration would silently be a second TimeProvider that nothing read.
            var clock = new ControllableTimeProvider(Origin + (advancedBy ?? TimeSpan.Zero));
            builder.Services.AddSingleton<TimeProvider>(clock);

            builder.Services.AddProblemDetails();
            builder.Services.ConfigureHttpJsonOptions(
                http => AiJsonConfiguration.Apply(http.SerializerOptions));

            var app = builder.Build();
            app.MapGatewayEndpoints();

            // The operator surface, mapped so that a recovery can be read back the way an operator
            // reads it. The recovery claim is about what the estate decided and what it still
            // remembers; asserting it only through the caller's response would prove that a request
            // succeeded and nothing about what the estate recorded.
            app.MapOperationsEndpoints();

            await app.StartAsync();

            var address = app.Urls.FirstOrDefault();

            Assert.True(
                !string.IsNullOrWhiteSpace(address),
                "the estate must report the address it bound; the server started but published none");

            return new Estate
            {
                _app = app,
                Client = new HttpClient { BaseAddress = new Uri(address!) },
                Provider = provider,
                Clock = clock,
            };
        }

        /// <summary>POSTs a capability request at the real gateway route.</summary>
        /// <remarks>
        /// The idempotency key is a parameter rather than a constant because the recovery claim is about
        /// re-execution: two calls that a correct estate must treat as separate work have to be
        /// expressible as separate work. `RequestId` stays constant across them, because the caller's
        /// identity is the thing being preserved.
        /// </remarks>
        public async Task<(HttpStatusCode Status, AiCapabilityResponse Response, string Body)> PostAsync(
            string idempotencyKey)
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, $"{AiGatewayContract.RoutePrefix}/invoke")
            {
                Content = new StringContent(RequestBody(RequestId, idempotencyKey), Encoding.UTF8, "application/json"),
            };

            request.Headers.TryAddWithoutValidation(AiGatewayContract.VersionHeader, AiGatewayContract.Version);

            using var httpResponse = await Client.SendAsync(request);
            var body = await httpResponse.Content.ReadAsStringAsync();

            Assert.True(
                httpResponse.StatusCode == HttpStatusCode.OK,
                $"the route must answer with a contract response even on failure, got "
                    + $"{(int)httpResponse.StatusCode}: {body}");

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

        /// <summary>
        /// The operator circuit read: every route's observed record and the circuit it has produced.
        /// </summary>
        /// <remarks>
        /// Read over HTTP from the estate's own operator route rather than reached into through DI. The
        /// claim being tested is that the estate <em>records</em> what it decided — a test that read the
        /// in-process object would prove that an object holds a value, and would pass unchanged if the
        /// record never reached a surface an operator has.
        /// </remarks>
        public async Task<IReadOnlyList<AiRouteOperationsRow>> ReadRoutesAsync()
        {
            using var response = await Client.GetAsync($"{OperationsEndpoints.RoutePrefix}/circuits");
            var body = await response.Content.ReadAsStringAsync();

            Assert.True(
                response.StatusCode == HttpStatusCode.OK,
                $"the operator circuit read must answer, got {(int)response.StatusCode}: {body}");

            var rows = JsonSerializer.Deserialize<AiRouteOperationsRow[]>(body, WireJson);

            Assert.True(rows is not null, $"the circuit read must deserialise: {body}");

            return rows!;
        }

        /// <summary>
        /// The gate that refused one execution, read from the operator's own execution surface.
        /// </summary>
        /// <remarks>
        /// Read by execution identifier rather than filtered out of the list read, because a refusal is
        /// the case where an execution selects no route and the reason for that is the thing an operator
        /// has to be able to resolve. If this surface could not answer for a refused execution, the
        /// refusal would be a status with no cause attached anywhere a person can reach.
        /// </remarks>
        public async Task<IReadOnlyList<AiRoutingRejectionReason>> ReadRefusalReasonsAsync(string executionId)
        {
            using var response = await Client.GetAsync(
                $"{OperationsEndpoints.RoutePrefix}/executions/{Uri.EscapeDataString(executionId)}");

            var body = await response.Content.ReadAsStringAsync();

            Assert.True(
                response.StatusCode == HttpStatusCode.OK,
                $"the operator execution read must answer, got {(int)response.StatusCode}: {body}");

            var view = JsonSerializer.Deserialize<AiExecutionOperationsView>(body, WireJson);

            Assert.True(view is not null, $"the execution read must deserialise: {body}");

            return [.. view!.RoutingRejections.Select(rejection => rejection.Reason)];
        }

        /// <summary>The registry document, as configuration declares it.</summary>
        private static AiRegistryConfiguration Registry() => new()
        {
            Provenance = "W7G recovery fixture.",
            Routing = new AiRoutingConfigurationEntry { Objective = "Balanced", FallbackDepth = 1 },
            Providers =
            [
                new AiProviderConfigurationEntry
                {
                    ProviderId = ProviderRegistration,
                    DisplayName = "W7G recovery fixture route",
                    AdapterIdentity = "Nexus.Intelligence.Architecture.Tests.Adapter.Recovery",
                    Capabilities = [AiCapabilities.ChatComplete],
                    Enabled = true,

                    // A REFERENCE, never a value, and nothing resolves it.
                    SecretReference = "NEXUS_W7G_TEST_KEY",
                    PermitsRemoteEgress = false,
                    Trust = "Approved",
                    Priority = 10,
                    Weight = 1.0,
                    Approval = "Approved",
                    MaxClassification = "Secret",
                    ApprovedBy = "w7g-test-owner",
                    GovernanceRationale = "W7G recovery fixture.",
                },
            ],
            Models =
            [
                new AiModelConfigurationEntry
                {
                    ModelId = Model,
                    ProviderId = ProviderRegistration,
                    DisplayName = "W7G recovery fixture route",
                    Capabilities = [AiCapabilities.ChatComplete],
                    MaxContextTokens = 200_000,
                    MaxOutputTokens = 8_192,
                    InputModalities = ["Text"],
                    OutputModalities = ["Text"],
                    Reasoning = "High",
                    RelativeSpeed = "Normal",

                    // DECLARED "Available" AND THAT IS DELIBERATE, not an oversight. The subject of this
                    // suite is a provider that fails at INVOCATION time — the case a health declaration
                    // cannot anticipate and which no configuration change precedes. Declaring the model
                    // unhealthy instead would route around it and test the router's health handling,
                    // which is a different property and is already covered elsewhere. It also means the
                    // suite does not depend on the estate re-reading health between calls.
                    Availability = "Available",
                    Enabled = true,

                    // Unpriced, so the budget and cost gates have nothing to compare and cannot refuse.
                    Approval = "Approved",
                    MaxClassification = "Secret",
                    ApprovedBy = "w7g-test-owner",
                    GovernanceRationale = "W7G recovery fixture.",
                },
            ],
            Health =
            [
                new AiHealthConfigurationEntry { ProviderId = ProviderRegistration, State = "Available" },
                new AiHealthConfigurationEntry { ProviderId = ProviderRegistration, ModelId = Model, State = "Available" },
            ],
        };

        /// <summary>The whole estate's configuration: the registry, and the operational posture.</summary>
        private static string EstateJson(AiCircuitPolicy? recovery = null)
        {
            var operations = new Dictionary<string, object?>
            {
                ["Budget"] = new Dictionary<string, object?>
                {
                    ["Available"] = true,
                    ["OnUncoveredPricedExecution"] = "Refuse",
                    ["Rules"] = Array.Empty<object>(),
                },
            };

            if (recovery is not null)
            {
                operations["Recovery"] = new Dictionary<string, object?>
                {
                    ["Enabled"] = recovery.Enabled,
                    ["CooldownSeconds"] = (int)recovery.Cooldown.TotalSeconds,
                    ["ProbeAllowance"] = recovery.ProbeAllowance,
                    ["ProbeSuccessesRequired"] = recovery.ProbeSuccessesRequired,
                };
            }

            var root = new Dictionary<string, object?>
            {
                ["Ai"] = new Dictionary<string, object?>
                {
                    [AiRegistryConfiguration.SectionName.Split(':')[1]] = Registry(),
                    ["Operations"] = operations,
                },
            };

            return JsonSerializer.Serialize(root, new JsonSerializerOptions
            {
                DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            });
        }

        /// <summary>The caller's request, exactly as a consumer would put it on the wire.</summary>
        private static string RequestBody(string requestId, string idempotencyKey) =>
            $$"""
            {
              "requestId": "{{requestId}}",
              "capability": "{{Capability}}",
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
              "correlationId": "correlation-w7g-recovery",
              "idempotencyKey": "{{idempotencyKey}}"
            }
            """;
    }

    /// <summary>
    /// One provider implementation that can be switched between failing and answering.
    /// </summary>
    /// <remarks>
    /// <para>
    /// It implements <see cref="INamedModelGateway"/> — the interface a real provider package
    /// implements — so the estate's real routing and step components run above it. It holds no
    /// credential, opens no socket and resolves no secret reference.
    /// </para>
    /// <para>
    /// <see cref="Healthy"/> is <c>volatile</c> because the switch is written by the test thread and
    /// read by a Kestrel request thread. Without it the write could sit in a register and the estate
    /// would appear to recover only intermittently, which is the worst possible failure in a recovery
    /// test: it would look like a real latch.
    /// </para>
    /// </remarks>
    private sealed class SwitchableProviderGateway(string vendor) : INamedModelGateway
    {
        private volatile bool _healthy = true;

        /// <summary>Whether the provider answers. Switched by the test; read by the request thread.</summary>
        public bool Healthy
        {
            get => _healthy;
            set => _healthy = value;
        }

        /// <summary>How many times this implementation was reached, healthy or not.</summary>
        public int Count;

        /// <summary>The last error text this implementation reported, for the control test.</summary>
        public string? LastError { get; private set; }

        /// <summary>The vendor token this implementation answers to.</summary>
        public string Vendor { get; } = vendor;

        public Task<ModelGatewayOutcome> InvokeReportingUsageAsync(ModelInvocation invocation, CancellationToken ct = default)
        {
            Interlocked.Increment(ref Count);

            if (!_healthy)
            {
                // The failure carries the provider's OWN text, exactly as a real adapter does
                // (`OpenAIModelGateway` assigns `ex.Message` here). That is what makes the
                // provider-neutrality assertions above non-vacuous: the text exists, it is distinctive,
                // and it must not reach the caller.
                LastError = ProviderMarkerText;

                // Unmeasured: a call that failed reported no usage.
                return Task.FromResult(ModelGatewayOutcome.Unmeasured(new ModelInvocationResult
                {
                    Success = false,
                    Error = ProviderMarkerText,
                    ModelUsed = invocation.ModelId,
                }));
            }

            LastError = null;

            // A REAL measurement, so the served path carries counts rather than nulls.
            return Task.FromResult(new ModelGatewayOutcome
            {
                Result = new ModelInvocationResult
                {
                    Success = true,
                    Message = new ModelMessage { Role = ModelRole.Assistant, Content = "answered" },
                    Usage = new ModelUsage(25, 5, 0m),
                    ModelUsed = invocation.ModelId,
                },
                TokensIn = 25,
                TokensOut = 5,
            });
        }

        public async Task<ModelInvocationResult> InvokeAsync(ModelInvocation invocation, CancellationToken ct = default)
            => (await InvokeReportingUsageAsync(invocation, ct).ConfigureAwait(false)).Result;

        public async IAsyncEnumerable<ModelStreamChunk> StreamAsync(
            ModelInvocation invocation,
            [EnumeratorCancellation] CancellationToken ct = default)
        {
            // Nothing in this suite streams; written as an async iterator so the compiler emits a real
            // enumerable rather than a throwing stub.
            await Task.CompletedTask;

            yield return new ModelStreamChunk("answered", true);
        }
    }

    /// <summary>The wire's own JSON options, so a test reads the response as a consumer would.</summary>
    private static readonly JsonSerializerOptions WireJson = CreateWireJson();

    /// <summary>
    /// A clock the test owns, so that a configured cooldown can elapse without a test waiting for it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Nothing else in the estate can move it.</b> It is registered as the estate's only
    /// <see cref="TimeProvider"/>, so the routing context's <c>Now</c>, the recorded attempt timestamps
    /// and the derived circuit state all read the same value — which is what makes an assertion about
    /// elapsed time an assertion about one clock rather than about two that happened to agree.
    /// </para>
    /// <para>
    /// Ticks are held in a <see cref="long"/> and moved with <see cref="Interlocked"/>, because the
    /// test thread advances the clock while Kestrel request threads read it. A non-atomic field would
    /// make the estate observe a torn timestamp exactly often enough to be a flaky suite.
    /// </para>
    /// </remarks>
    private sealed class ControllableTimeProvider : TimeProvider
    {
        private long _utcTicks;

        public ControllableTimeProvider(DateTimeOffset start) => _utcTicks = start.UtcTicks;

        public override DateTimeOffset GetUtcNow() =>
            new(Interlocked.Read(ref _utcTicks), TimeSpan.Zero);

        /// <summary>Moves the clock forward. Time in this estate only ever moves on.</summary>
        public void Advance(TimeSpan by)
        {
            Assert.True(by >= TimeSpan.Zero, "a test must not move the estate's clock backwards");

            Interlocked.Add(ref _utcTicks, by.Ticks);
        }
    }

    private static JsonSerializerOptions CreateWireJson()
    {
        // THE SAME configuration the server writes with. Both sides call `AiJsonConfiguration.Apply`,
        // so the server and this reader cannot drift into disagreeing about how an enum is spelled —
        // which is the failure mode that makes a contract test pass while the contract is broken.
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        AiJsonConfiguration.Apply(options);

        return options;
    }
}
