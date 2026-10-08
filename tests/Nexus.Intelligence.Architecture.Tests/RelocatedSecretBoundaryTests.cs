using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using Nexus.Platform.Contracts.Secrets;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W5G / F-01: RELOCATED from Nexus.Platform.Architecture.Tests/SecretBoundaryTests.cs,
// sections 3 and 4. The provider moved into this repository, so its half of the D-14 secret
// boundary moved with it.
//
// THIS IS A SECURITY CONTROL, NOT A TEST MOVE. These two tests were the only continuous
// regression lock on:
//   - W4L-201's blocking reason, verbatim: "REQUIRES_HUMAN_SECRET_ROTATION - OpenAIOptions
//     carries an ApiKey property and the provider is the credential consumer (D-14, Owner
//     decision #7)". Section 4 fails if a value-bearing property ever comes back.
//   - the adapter resolving through the neutral ISecretResolver boundary instead of reading
//     OPENAI_API_KEY from the environment. Section 3 fails if it regresses.
//
// Both are asserted at COMPILE time where possible, so a regression breaks this repository's
// build rather than merely failing a test run. The neutral half of the original file (no
// provider secret token may appear in a neutral Platform assembly, plus the scanner's
// non-vacuity proof) deliberately STAYED in Nexus.Platform.Architecture.Tests: it guards the
// Platform side of the same boundary, and moving it here would have pointed the assertion at
// the wrong repository.
//
// The scanner is duplicated rather than shared because a test assembly cannot reference a
// sibling test assembly's internals cleanly, and a shared test helper package would be a
// larger change than the guard is worth. The duplication is safe in one direction that
// matters: each copy's non-vacuity proof runs against its OWN assembly, so neither can pass
// by being unable to see anything.
public sealed class RelocatedSecretBoundaryTests
{
    private static Assembly ProviderAssembly => typeof(Nexus.Platform.Providers.OpenAI.OpenAIModelGateway).Assembly;

    // Original section 3: ProviderAdapter_MayDependOn_NeutralSecretContract
    [Fact]
    public void ProviderAdapter_MayDependOn_NeutralSecretContract()
    {
        var ctor = Assert.Single(typeof(Nexus.Platform.Providers.OpenAI.OpenAIModelGateway).GetConstructors());

        Assert.Contains(ctor.GetParameters(), p => p.ParameterType == typeof(ISecretResolver));

        // The contract must still come from the Platform Contract Plane, not from a copy that
        // grew inside the AI Head.
        Assert.Equal("Nexus.Platform.Contracts", typeof(ISecretResolver).Assembly.GetName().Name);

        // The adapter must not have regressed to reading the environment itself.
        Assert.False(
            AssemblyContainsToken(ProviderAssembly, "OPENAI_API_KEY"),
            "The OpenAI adapter reads the provider environment variable directly instead of "
            + "resolving through the neutral ISecretResolver boundary (D-14 regression).");
    }

    // Original section 4: ProviderOptions_CarrySecretReferences_NeverSecretValues
    [Fact]
    public void ProviderOptions_CarrySecretReferences_NeverSecretValues()
    {
        var valueBearing = new[] { "apikey", "key", "secret", "token", "password", "credential" };

        var offenders = typeof(Nexus.Platform.Providers.OpenAI.OpenAIOptions)
            .GetProperties()
            .Where(p => valueBearing.Any(bad => p.Name.Equals(bad, StringComparison.OrdinalIgnoreCase)))
            .Select(p => p.Name)
            .ToList();

        Assert.True(
            offenders.Count == 0,
            "OpenAIOptions has regressed to carrying a secret VALUE. W4L-201's blocking reason was "
            + "verbatim 'REQUIRES_HUMAN_SECRET_ROTATION - OpenAIOptions carries an ApiKey property and "
            + "the provider is the credential consumer (D-14, Owner decision #7)'. Offenders: "
            + string.Join(", ", offenders));

        // Positive half, asserted at COMPILE time: if ApiKeyRef is ever removed this test
        // assembly stops compiling, which is the hardest form of regression lock available.
        var apiKeyRef = new Nexus.Platform.Providers.OpenAI.OpenAIOptions().ApiKeyRef;

        Assert.NotNull(apiKeyRef);
        Assert.IsType<string>(apiKeyRef);
    }

    // Non-vacuity proof for the scanner used above. Without this, a scanner that silently
    // fails to read any assembly would make the OPENAI_API_KEY assertion in section 3 pass
    // forever - a check that cannot fail.
    [Fact]
    public void TokenScanner_IsNonVacuous_OnProviderAssembly()
    {
        // Positive control: the scanner must find a token that is GUARANTEED to be in the
        // provider assembly's #US (user-string) heap. "openai" is one such literal - it is
        // the value of OpenAIModelGateway.Vendor and of every descriptor's Vendor field in
        // OpenAIModelCatalogSource - so a scanner that cannot see it cannot see anything.
        //
        // The control is deliberately a real product literal rather than a fixture one. The
        // original Platform-side proof used a fixture constant in the TEST assembly, which
        // proved the scanner worked but not that it worked on the assembly actually being
        // asserted about. Note that type and namespace NAMES would NOT have worked as a
        // control here: those live in the #Strings heap as UTF-8, and this scanner searches
        // for UTF-16LE. A control chosen carelessly would have failed for the wrong reason.
        Assert.True(
            AssemblyContainsToken(ProviderAssembly, "openai"),
            "The token scanner failed to detect a known-present literal in the provider assembly. "
            + "The OPENAI_API_KEY assertion above is therefore vacuous.");

        // Negative control: a token that cannot be present is not reported. Guid.NewGuid() is
        // not a compile-time constant, so no literal for this value can exist in the assembly.
        var absentToken = "NEXUS_ABSENT_" + Guid.NewGuid().ToString("N");

        Assert.False(
            AssemblyContainsToken(ProviderAssembly, absentToken),
            "The token scanner reported a token that cannot exist; it is matching everything.");
    }

    /// <summary>
    /// Scans a compiled assembly for a token. The <c>#US</c> (user-string) metadata heap
    /// stores literals as UTF-16LE, so a UTF-16 byte search finds string literals anywhere in
    /// the assembly - including inside method bodies, which reflection alone cannot reach.
    /// </summary>
    private static bool AssemblyContainsToken(Assembly assembly, string token)
    {
        var path = assembly.Location;
        if (string.IsNullOrEmpty(path) || !File.Exists(path))
        {
            return false;
        }

        var haystack = File.ReadAllBytes(path);
        var needle = Encoding.Unicode.GetBytes(token);

        return IndexOf(haystack, needle) >= 0;
    }

    private static int IndexOf(byte[] haystack, byte[] needle)
    {
        if (needle.Length == 0 || haystack.Length < needle.Length)
        {
            return -1;
        }

        var limit = haystack.Length - needle.Length;
        for (var i = 0; i <= limit; i++)
        {
            var matched = true;
            for (var j = 0; j < needle.Length; j++)
            {
                if (haystack[i + j] != needle[j])
                {
                    matched = false;
                    break;
                }
            }

            if (matched)
            {
                return i;
            }
        }

        return -1;
    }
}
