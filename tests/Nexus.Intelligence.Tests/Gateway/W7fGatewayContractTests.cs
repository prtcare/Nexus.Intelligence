using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Nexus.Intelligence.Contracts;
using Xunit;

namespace Nexus.Intelligence.Tests.Gateway;

// W7F TASK 14: the public gateway contract's compatibility and version strategy, exercised as behaviour
// rather than stated as prose.
//
// WHY A CONTRACT VERSION AT ALL, AND WHY IT IS NOT THE ASSEMBLY VERSION. Before W7F the only version a
// caller could read was the AI Head assembly's own, served from the capabilities endpoint. Those are
// different numbers answering different questions: an assembly version moves on every refactor, every
// hotfix and every dependency bump, and a consumer that branched on it would break on a release that
// changed nothing it could observe. The contract version moves only when the contract does, which is
// what makes it something a consumer can hold.
//
// WHAT THESE TESTS ARE FOR. The compatibility predicate is the one piece of the strategy a consumer
// acts on without reading any remarks, so it is asserted from both sides: what it accepts, and what it
// refuses. A predicate that accepted everything would make the version decorative.
public sealed class W7fGatewayContractTests
{
    // ---------------------------------------------------------------------------------------------
    // TASK 14: the version token belongs to the contract.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheContractVersion_IsTheContractsOwn_AndNotTheImplementationAssemblys()
    {
        // The version is stated by the contract's own constants, so it cannot move without an edit to
        // this file's subject rather than to a build number.
        Assert.Equal(
            $"{AiGatewayContract.MajorVersion}.{AiGatewayContract.MinorVersion}",
            AiGatewayContract.Version);

        // ...and it is demonstrably a different number from the assembly's. This is the assertion that
        // would fail if someone re-coupled the two by setting the contract version to the assembly
        // version - which is exactly the coupling TASK 14 forbids, and which would otherwise be
        // invisible because both are strings that look like versions.
        var assemblyVersion = typeof(AiGatewayContract).Assembly.GetName().Version?.ToString() ?? "(none)";

        Assert.NotEqual(assemblyVersion, AiGatewayContract.Version);

        // NON-VACUITY: the assembly really does carry a version, so the inequality above is a statement
        // about two present numbers rather than about one of them being absent.
        Assert.NotEqual("(none)", assemblyVersion);
    }

    [Fact]
    public void TheContractRoute_NamesItsMajorVersion_AndAgreesWithTheVersionToken()
    {
        // The major version appears in the path and in the header. Both are read from one place, so a
        // caller that discovers the version by negotiation and a caller that hard-codes a path cannot be
        // sent to different contracts.
        Assert.StartsWith("/", AiGatewayContract.RoutePrefix, StringComparison.Ordinal);

        Assert.Contains(
            $"/v{AiGatewayContract.MajorVersion}",
            AiGatewayContract.RoutePrefix,
            StringComparison.Ordinal);

        // The header name is a literal a caller compiles in, so it is asserted rather than left to drift
        // silently: a renamed header would break every consumer at once with no contract change to point
        // at.
        Assert.Equal("Nexus-Ai-Contract-Version", AiGatewayContract.VersionHeader);
        Assert.Equal("nexus.ai.gateway", AiGatewayContract.Name);
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 14: the compatibility rule, applied rather than interpreted.
    // ---------------------------------------------------------------------------------------------

    [Theory]
    [InlineData("1.0")]     // built against exactly what is served
    [InlineData("1")]       // a minor component is optional
    [InlineData("1.3")]     // built against a LATER minor: every member it knows is still served
    [InlineData("1.0.0")]   // a three-part version
    [InlineData("1.2.3.4")] // four parts, which is as far as System.Version goes
    public void ACallerOnThisMajorVersion_IsCompatible(string callerVersion)
    {
        Assert.True(
            AiGatewayContract.IsCompatibleWith(callerVersion),
            $"'{callerVersion}' is within the served major version {AiGatewayContract.MajorVersion} and "
            + "must be accepted: the contract is additive within a major version, so a caller on a lower "
            + "minor sees a subset and a caller on a higher minor was built against a superset.");
    }

    [Theory]
    [InlineData("0.9")]     // the major version before this one
    [InlineData("2.0")]     // the major version after it
    [InlineData("10.0")]    // a major that merely starts with the served digit
    [InlineData("")]        // nothing stated
    [InlineData("   ")]     // whitespace is not a version
    [InlineData("v1")]      // a prefixed token this contract does not define
    [InlineData("one")]     // not a number
    [InlineData("-1")]      // negative is not a version
    [InlineData("1.x")]     // a valid major with a non-numeric minor is still not a version
    [InlineData("1.")]      // a trailing separator is not a component
    [InlineData("1.0.x")]   // garbage in a component the rule does not read
    [InlineData("1.0.0.0.0")] // more components than a version can have
    public void ACallerOnAnotherMajorVersion_OrWithNoParseableVersion_IsNotCompatible(string callerVersion)
    {
        Assert.False(
            AiGatewayContract.IsCompatibleWith(callerVersion),
            $"'{callerVersion}' does not establish a version this contract defines, or names another "
            + "major version. Unknown is not a synonym for acceptable: the argument for tolerating a "
            + "skew rests on knowing which way it runs.");
    }

    [Fact]
    public void NoCallerVersion_IsNotCompatible()
    {
        // Null arrives from a caller that never stated a version at all - an absent header, a field
        // missing from a payload. Distinct from the empty string in provenance and identical in
        // meaning, and both must be refused rather than defaulted to the served version.
        Assert.False(AiGatewayContract.IsCompatibleWith(null));
    }

    [Fact]
    public void TheCompatibilityPredicate_IsNotVacuous_ItAcceptsAndRefusesFromTheSameShape()
    {
        // Every accepted input and every refused input above has the same shape - a short string - so a
        // predicate that returned a constant would have to fail one of the two theories. Asserted here
        // as a pair on the exact same major/minor boundary so the boundary itself is pinned rather than
        // only the far-apart cases.
        Assert.True(AiGatewayContract.IsCompatibleWith($"{AiGatewayContract.MajorVersion}.0"));
        Assert.False(AiGatewayContract.IsCompatibleWith($"{AiGatewayContract.MajorVersion + 1}.0"));
        Assert.False(AiGatewayContract.IsCompatibleWith($"{AiGatewayContract.MajorVersion - 1}.0"));
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 7: availability, and the two readings a caller must not confuse.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void UnknownAvailability_IsNotServable_AndIsNotTheSameAsUnavailable()
    {
        // The whole reason Unknown is a member: a caller that read "we never checked" as "it is up"
        // attempts work it cannot complete, and a caller that read it as "it is down" takes the
        // deterministic path during every probe window of the monitoring plane itself.
        var unknown = new AiCapabilityAvailability
        {
            Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
            State = AiAvailabilityState.Unknown,
        };

        var unavailable = unknown with { State = AiAvailabilityState.Unavailable };

        Assert.False(unknown.IsServable);
        Assert.False(unavailable.IsServable);

        // ...and they are still distinguishable, which is the point: a build that collapsed them would
        // satisfy both assertions above.
        Assert.NotEqual(unknown.State, unavailable.State);

        // NON-VACUITY: the proceedable states are servable from the same type, so IsServable is a
        // reading rather than a constant false.
        Assert.True((unknown with { State = AiAvailabilityState.Available }).IsServable);
        Assert.True((unknown with { State = AiAvailabilityState.Degraded }).IsServable);

        // Degraded is servable and is NOT available, which is the pair a caller branches on: proceed,
        // expecting a reduced answer rather than a refusal.
        Assert.NotEqual(AiAvailabilityState.Available, AiAvailabilityState.Degraded);
    }

    [Fact]
    public void TheHeadIsServable_OnTheSameRuleAsACapability()
    {
        // Two types carry the same reading, so a caller cannot learn one rule for the Head and another
        // for a capability - which is how "the Head is fine but this capability is not" becomes "both
        // are fine" at one call site and "both are down" at the next.
        foreach (var state in Enum.GetValues<AiAvailabilityState>())
        {
            var head = new AiGatewayAvailability { State = state, ObservedAt = DateTimeOffset.UnixEpoch };
            var capability = new AiCapabilityAvailability
            {
                Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
                State = state,
            };

            Assert.Equal(capability.IsServable, head.IsServable);
        }

        // NON-VACUITY: the loop above is only meaningful if the states do not all agree, so the two
        // readings are asserted to differ across the set.
        var readings = Enum.GetValues<AiAvailabilityState>()
            .Select(state => new AiCapabilityAvailability
            {
                Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
                State = state,
            }.IsServable)
            .Distinct()
            .ToArray();

        Assert.Equal(2, readings.Length);
    }

    [Fact]
    public void AnUnrecognisedCapability_IsAbsent_RatherThanReportedAsUnavailable()
    {
        var reported = CapabilityId.Parse(AiCapabilities.ChatComplete);
        var unknown = CapabilityId.Parse("code.review");

        var availability = new AiGatewayAvailability
        {
            State = AiAvailabilityState.Available,
            ObservedAt = DateTimeOffset.UnixEpoch,
            Capabilities =
            [
                new AiCapabilityAvailability
                {
                    Capability = reported,
                    State = AiAvailabilityState.Available,
                },
            ],
        };

        Assert.NotNull(availability.CapabilityFor(reported));

        // Absent, not an unservable entry. A caller told "unavailable" for a capability that does not
        // exist would retry a request that can never succeed; the typed failure for that case is
        // CapabilityNotFound, raised when it is actually invoked.
        Assert.Null(availability.CapabilityFor(unknown));

        // ...and the Head's own state is unaffected by the question, so the absence is a statement about
        // the capability rather than a refusal of the caller.
        Assert.True(availability.IsServable);
    }

    [Fact]
    public void TheAvailabilityDocument_CarriesTheContractVersion_ByDefault()
    {
        // Availability is the one call a caller makes before it knows anything about the Head, so the
        // version is answered there and the caller does not have to spend a capability invocation to
        // ask whether this is the contract it was built against.
        var availability = new AiGatewayAvailability
        {
            State = AiAvailabilityState.Available,
            ObservedAt = DateTimeOffset.UnixEpoch,
        };

        Assert.Equal(AiGatewayContract.Version, availability.ContractVersion);
        Assert.True(AiGatewayContract.IsCompatibleWith(availability.ContractVersion));
    }

    [Fact]
    public void TheAvailabilityVocabulary_IsProviderNeutral_ByConstruction()
    {
        // TASK 7's "do not expose raw provider health internals to Product callers" is asserted
        // structurally in the architecture suite, where the walker can prove it reaches a health type
        // from a root that legitimately carries one. What is asserted here is the narrower, cheaper
        // fact the vocabulary is closed for: every reason is expressible without naming a route, so a
        // detail string has nothing to say that the enum cannot.
        //
        // A reason must therefore never be the thing that discloses which route failed. If a future
        // member needs a provider name to be legible, the member is wrong rather than the rule.
        var reasons = Enum.GetNames<AiAvailabilityReason>();

        Assert.Contains(nameof(AiAvailabilityReason.None), reasons);
        Assert.Contains(nameof(AiAvailabilityReason.NoUsableRoute), reasons);

        // A closed vocabulary, so it is small enough to review in one screen. A member added per
        // provider failure mode would make this the leak it exists to prevent.
        Assert.True(
            reasons.Length <= 12,
            "AiAvailabilityReason has grown past the size at which it can be reviewed as a closed "
            + "vocabulary. A member per failure mode is how a provider-neutral reason becomes a "
            + "provider-shaped one.");
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 3: the one member the frozen response contract did not yet carry.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AFallback_IsReportedToTheCaller_WithoutNamingWhatItFellBackTo()
    {
        // TASK 3 names "fallback occurred" as part of the response contract. It is caller-facing
        // information because it is the only signal a caller has that its answer came from a secondary
        // route - and it is provider-independent because the routes are not named.
        var response = new AiCapabilityResponse
        {
            RequestId = "req-w7f-fallback",
            Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
            CorrelationId = "corr-w7f-fallback",
            Status = AiExecutionStatus.Succeeded,
            Output = "an answer that came from somewhere",
            UsedFallback = true,
        };

        Assert.True(response.UsedFallback);

        // A fallback completed and produced a real answer, so it is NOT a degraded result - the two are
        // independent, and a build that derived one from the other would report a successful fallback
        // as though nothing had run.
        Assert.False(response.IsDegraded);

        // NON-VACUITY: the member is a reading rather than a constant. Same type, one field changed.
        Assert.False((response with { UsedFallback = false }).UsedFallback);

        // ...and nothing on the caller-facing response names a route. This is the assertion that would
        // fail if fallback reporting were implemented by publishing the failover record.
        var names = typeof(AiCapabilityResponse)
            .GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Select(property => property.Name)
            .ToArray();

        Assert.DoesNotContain(names, name => name.Contains("Provider", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(names, name => name.Contains("Model", StringComparison.OrdinalIgnoreCase));
    }
}
