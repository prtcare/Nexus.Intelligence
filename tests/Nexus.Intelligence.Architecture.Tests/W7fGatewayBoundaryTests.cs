using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7F TASK 7 and TASK 13: the deterministic proofs that the gateway's caller-facing contract discloses
// no provider internals and no secret.
//
// WHY STRUCTURAL RATHER THAN BEHAVIOURAL. The gateway's implementation is tested by asserting what it
// returns. These assertions are about what it CAN return - what the types make expressible - because the
// failure mode being guarded against is a member added later for a good local reason, not a bug in a
// projection written today. A behavioural test cannot see a member that does not exist yet; a walker
// over the contract's reachable types can.
//
// EVERY DETECTOR HERE CARRIES A NON-VACUITY PROOF, and the health-type one is the sharpest: the same
// walker is shown to FIND a health type from a root that legitimately carries one. A detector that
// cannot find the thing it forbids proves nothing by finding nothing.
public sealed class W7fGatewayBoundaryTests
{
    private static Assembly ContractsAssembly =>
        typeof(Nexus.Intelligence.Contracts.AiGatewayAvailability).Assembly;

    /// <summary>Every caller-facing type the gateway contract publishes.</summary>
    /// <remarks>
    /// The operation-side types are deliberately NOT roots. <c>AiExecutionOperationsView</c> carries
    /// <c>ProviderId</c>, <c>ModelId</c> and <c>ModelHealth</c> on purpose: it is an operator surface
    /// under authority, and TASK 3 requires provider and model as evidence of what happened. Scanning
    /// the whole assembly would assert the opposite of that requirement - the same scoping decision the
    /// W7A boundary suite records, made again here because a gateway contract is what was added.
    /// </remarks>
    private static Type[] GatewayRoots =>
    [
        typeof(Nexus.Intelligence.Contracts.IAiCapabilityClient),
        typeof(Nexus.Intelligence.Contracts.AiCapabilityRequest),
        typeof(Nexus.Intelligence.Contracts.AiCapabilityResponse),
        typeof(Nexus.Intelligence.Contracts.IAiGatewayAvailabilitySource),
        typeof(Nexus.Intelligence.Contracts.AiGatewayAvailability),
        typeof(Nexus.Intelligence.Contracts.AiCapabilityAvailability),
        typeof(Nexus.Intelligence.Contracts.AiGatewayContract),
    ];

    // ---------------------------------------------------------------------------------------------
    // TASK 7: the availability contract reaches no provider health internals.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheAvailabilityContract_ReachesNoProviderHealthType()
    {
        // AiModelHealthState is the estate's health vocabulary: it states how a PROVIDER and a MODEL
        // are reported. A caller that could read it would be reading the AI Head's provider plane, and
        // TASK 7 forbids publishing that. The availability contract states a conclusion instead -
        // servable or not, and a provider-neutral reason.
        var offenders = ReachableTypes(GatewayRoots)
            .Where(IsProviderHealthType)
            .Select(t => $"{t.FullName} (from {t.Assembly.GetName().Name})")
            .Distinct()
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();

        Assert.True(
            offenders.Length == 0,
            "[W7F-T7] The caller-facing gateway contract reaches a provider health type. A Product must "
            + "be able to ask whether a capability is available without learning how the estate's "
            + "providers are faring. Offenders: " + string.Join(", ", offenders));
    }

    [Fact]
    public void TheProviderHealthWalker_IsNonVacuous_ItFindsAHealthTypeWhereOneExists()
    {
        // The control that makes the assertion above mean something. The operations view is an
        // OPERATOR type and carries ModelHealth of type AiModelHealthState on purpose, so the walker
        // must find a health type when it walks a root that legitimately carries one. Without this, a
        // walker that silently reached nothing would report zero offenders forever.
        var found = ReachableTypes([typeof(Nexus.Intelligence.Contracts.AiExecutionOperationsView)])
            .Where(IsProviderHealthType)
            .ToArray();

        Assert.NotEmpty(found);

        // ...and the detector recognises the estate's health vocabulary by identity rather than by a
        // name pattern, so it cannot be defeated by aliasing the type.
        Assert.True(IsProviderHealthType(typeof(Nexus.Intelligence.Contracts.AiModelHealthState)));

        // The negative direction: a neutral availability state must NOT be flagged, or the rule would be
        // satisfiable by renaming rather than by removing the disclosure.
        Assert.False(IsProviderHealthType(typeof(Nexus.Intelligence.Contracts.AiAvailabilityState)));
        Assert.False(IsProviderHealthType(typeof(Nexus.Intelligence.Contracts.AiAvailabilityReason)));
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 13: the gateway exposes no secret, and no secret-shaped member exists to expose.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void NoCallerFacingGatewayMember_IsSecretShaped()
    {
        // The names a secret would have to travel under. A member called SecretReference is not itself a
        // secret - it is a NAME - but it is a name only the AI Head's registry has any use for, and a
        // caller-facing type that carries one is a caller-facing type that has begun to mirror the
        // registry. TASK 13 forbids the registry surface reaching ordinary callers.
        var offenders = ReachableTypes(GatewayRoots)
            .SelectMany(type => type
                .GetProperties(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static)
                .Select(property => (Type: type, Member: property.Name)))
            .Where(member => IsSecretShapedName(member.Member))
            .Select(member => $"{member.Type.Name}.{member.Member}")
            .Distinct()
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();

        Assert.True(
            offenders.Length == 0,
            "[W7F-T13] A caller-facing gateway member is secret-shaped. The gateway must not expose "
            + "secret values, raw provider config, or the registry's secret-reference identifiers to "
            + "ordinary callers. Offenders: " + string.Join(", ", offenders));
    }

    [Fact]
    public void TheSecretShapedNameDetector_IsNonVacuous_AndDoesNotFlagTokenAccounting()
    {
        // Positive direction: the detector recognises the shapes a secret travels under.
        foreach (var planted in new[]
        {
            "Credential", "ApiKey", "SecretReference", "BearerToken", "AuthorizationHeader", "Password",
        })
        {
            Assert.True(
                IsSecretShapedName(planted),
                $"The secret-shaped name detector does not recognise '{planted}'. The W7F-T13 assertion "
                + "above is therefore vacuous for that class of leak.");
        }

        // Negative direction, and this one is load-bearing rather than cosmetic: AiTokenUsage's
        // InputTokens and OutputTokens are token ACCOUNTING, and the caller-facing response carries them
        // on purpose so a caller can meter its own usage. A detector that flagged the word "token" would
        // force those members to be renamed to satisfy a rule, which is how a boundary rule stops
        // describing the boundary and starts describing a naming convention.
        foreach (var accounting in new[] { "InputTokens", "OutputTokens", "CachedInputTokens", "Usage" })
        {
            Assert.False(
                IsSecretShapedName(accounting),
                $"The detector flags '{accounting}', which is token accounting rather than a credential. "
                + "The rule would then be satisfied by renaming a legitimate member.");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 14: the contract version is the contract's own, not the implementation's.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheContractVersion_IsDeclaredByTheContractAssembly()
    {
        // A caller reads the version from the contract it compiled against. If the token lived in the
        // API or Core assembly, a consumer would have to reference an implementation assembly to learn
        // what it is talking to - which is the coupling TASK 14 names.
        Assert.Same(ContractsAssembly, typeof(Nexus.Intelligence.Contracts.AiGatewayContract).Assembly);

        // ...and no caller-facing gateway type exposes a reflection handle to an assembly, which is how
        // an implementation version reaches a consumer dressed as a contract version.
        var offenders = ReachableTypes(GatewayRoots)
            .Where(type => type.Namespace is not null
                           && type.Namespace.StartsWith("System.Reflection", StringComparison.Ordinal))
            .Select(type => type.FullName ?? type.Name)
            .Distinct()
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();

        Assert.True(
            offenders.Length == 0,
            "[W7F-T14] A caller-facing gateway type exposes a reflection type. Offenders: "
            + string.Join(", ", offenders));
    }

    // ---------------------------------------------------------------------------------------------
    // Detectors.
    // ---------------------------------------------------------------------------------------------

    /// <summary>The estate's provider health vocabulary, by identity.</summary>
    /// <remarks>
    /// Named one by one rather than matched on a pattern, because the boundary being guarded is about
    /// the facts a type carries and not about the words in its name. The name clause in the detector
    /// below is the belt to this braces: it catches a health type added later that nobody added to this
    /// list, which is the realistic way this rule would otherwise rot.
    /// </remarks>
    private static readonly Type[] KnownProviderHealthTypes =
    [
        typeof(Nexus.Intelligence.Contracts.AiModelHealthState),
        typeof(Nexus.Intelligence.Contracts.AiHealthProbeOutcome),
        typeof(Nexus.Intelligence.Contracts.IAiModelHealthSource),
        typeof(Nexus.Intelligence.Contracts.IAiHealthSnapshotStore),
    ];

    /// <summary>True when a type belongs to the estate's provider health vocabulary.</summary>
    private static bool IsProviderHealthType(Type type)
        => KnownProviderHealthTypes.Contains(type)
           || type.Name.Contains("Health", StringComparison.Ordinal);

    /// <summary>True when a member name is one a credential or a registry secret reference travels under.</summary>
    /// <remarks>
    /// "Token" alone is deliberately absent: token accounting is a legitimate caller-facing fact, and a
    /// rule that forbade the word would be satisfied by renaming rather than by removing a disclosure.
    /// The credential-bearing shapes are the qualified ones.
    /// </remarks>
    private static bool IsSecretShapedName(string name)
    {
        string[] fragments =
        [
            "secret", "credential", "apikey", "api_key", "password", "bearer", "authorization",
            "privatekey", "connectionstring",
        ];

        return fragments.Any(fragment => name.Contains(fragment, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// Every type reachable from a set of roots through public members and generic arguments.
    /// </summary>
    /// <remarks>
    /// Descends only into the contract assembly. A framework type cannot expose a Nexus type, and
    /// descending into one would pull in the whole of System.Runtime for nothing.
    /// </remarks>
    private static HashSet<Type> ReachableTypes(IEnumerable<Type> roots)
    {
        var seen = new HashSet<Type>();
        var queue = new Queue<Type>();

        foreach (var root in roots)
        {
            foreach (var type in Unwrap(root))
            {
                queue.Enqueue(type);
            }
        }

        while (queue.Count > 0)
        {
            var current = queue.Dequeue();

            if (!seen.Add(current))
            {
                continue;
            }

            if (current.Assembly != ContractsAssembly)
            {
                continue;
            }

            foreach (var member in PublicTypesOf(current))
            {
                queue.Enqueue(member);
            }
        }

        return seen;
    }

    private static IEnumerable<Type> PublicTypesOf(Type type)
    {
        const BindingFlags Flags =
            BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly;

        foreach (var property in type.GetProperties(Flags))
        {
            foreach (var unwrapped in Unwrap(property.PropertyType))
            {
                yield return unwrapped;
            }
        }

        foreach (var method in type.GetMethods(Flags))
        {
            foreach (var unwrapped in Unwrap(method.ReturnType))
            {
                yield return unwrapped;
            }

            foreach (var parameter in method.GetParameters())
            {
                foreach (var unwrapped in Unwrap(parameter.ParameterType))
                {
                    yield return unwrapped;
                }
            }
        }
    }

    /// <summary>Unwraps a type to the types it carries: generic arguments, array elements and by-ref targets.</summary>
    private static IEnumerable<Type> Unwrap(Type type)
    {
        if (type.IsByRef || type.IsArray || type.IsPointer)
        {
            var element = type.GetElementType();
            if (element is not null)
            {
                foreach (var inner in Unwrap(element))
                {
                    yield return inner;
                }
            }

            yield break;
        }

        yield return type;

        if (!type.IsGenericType)
        {
            yield break;
        }

        foreach (var argument in type.GetGenericArguments())
        {
            foreach (var inner in Unwrap(argument))
            {
                yield return inner;
            }
        }
    }
}
