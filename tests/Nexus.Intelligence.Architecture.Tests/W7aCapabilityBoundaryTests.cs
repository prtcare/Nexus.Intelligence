using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using NetArchTest.Rules;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7A / Task 13: the deterministic proofs for the AI capability, result, failure and contract-plane
// boundaries. Each proof carries a negative fixture that is asserted to FAIL the same detector, so no
// assertion here can pass merely because its detector cannot see anything. That requirement is not
// decorative: the failure mode these guard against is a scanner that silently reads nothing and
// reports success forever.
public sealed class W7aCapabilityBoundaryTests
{
    private static Assembly ContractsAssembly =>
        typeof(Nexus.Intelligence.Contracts.AiCapabilityRequest).Assembly;

    private static Assembly PlatformContractsAssembly =>
        typeof(Nexus.Platform.Contracts.Secrets.ISecretResolver).Assembly;

    // ---------------------------------------------------------------------------------------------
    // Rule W7A-T13(a): a Product can request a semantic capability without naming a provider.
    // ---------------------------------------------------------------------------------------------

    // The caller-facing capability surface is scanned for provider- and model-selecting members. The
    // scan deliberately starts at the CALLER-FACING roots only, and does not reach AiExecutionResult:
    // the directive requires provider and model on the result contract as evidence of what happened,
    // and forbids them on what the caller chooses. Scanning the whole assembly would assert the
    // opposite of Task 3 and would have to be weakened to pass - which is how a rule stops meaning
    // anything.
    [Fact]
    public void Product_RequestsSemanticCapability_WithoutNamingProvider()
    {
        Type[] callerFacingRoots =
        [
            typeof(Nexus.Intelligence.Contracts.AiCapabilityRequest),
            typeof(Nexus.Intelligence.Contracts.AiCapabilityResponse),
            typeof(Nexus.Intelligence.Contracts.AiCapabilityRegistration),
            typeof(Nexus.Intelligence.Contracts.IAiCapabilityClient),
        ];

        var offenders = ReachableTypes(callerFacingRoots)
            .SelectMany(t => t.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            .Where(p => IsProviderSelectingName(p.Name))
            .Select(p => $"{p.DeclaringType?.Name}.{p.Name}")
            .Distinct()
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();

        Assert.True(
            offenders.Length == 0,
            "[W7A-T13(a)] A caller must not be able to select a provider, a model or an endpoint. The "
            + "caller-facing capability contract exposes members that name one. Offenders: "
            + string.Join(", ", offenders));
    }

    // Negative fixture for the scanner above. Without this, a detector with an empty reachable set or a
    // mis-typed pattern would report zero offenders and the assertion would pass for the wrong reason.
    [Fact]
    public void ProviderSelectingNameScanner_IsNonVacuous_OnLeakyFixture()
    {
        var leaky = new[]
        {
            new KeyValuePair<string, string>("ModelHint", "the exact leak M1B recorded in TurnConstraints"),
            new KeyValuePair<string, string>("ProviderName", "the leak M1B recorded in UsageSummary"),
            new KeyValuePair<string, string>("Endpoint", "a provider endpoint chosen by the caller"),
        };

        foreach (var (name, why) in leaky)
        {
            Assert.True(
                IsProviderSelectingName(name),
                $"The provider-selecting name scanner does not recognise '{name}' ({why}). The "
                + "W7A-T13(a) assertion above is therefore vacuous for this class of leak.");
        }

        // Negative control in the other direction: ordinary capability vocabulary must not be flagged,
        // or the rule would be satisfied by renaming rather than by removing the leak.
        foreach (var benign in new[] { "Capability", "Purpose", "Requester", "Classification", "CorrelationId" })
        {
            Assert.False(
                IsProviderSelectingName(benign),
                $"The scanner flags '{benign}', which is ordinary capability vocabulary. The rule would "
                + "then be satisfied by renaming a leak rather than by removing it.");
        }

        // And the detector must actually reach types through the walker, not just classify names.
        var reachable = ReachableTypes([typeof(Nexus.Intelligence.Contracts.IAiCapabilityClient)]);
        Assert.Contains(typeof(Nexus.Intelligence.Contracts.AiCapabilityResponse), reachable);
        Assert.Contains(typeof(Nexus.Intelligence.Contracts.CapabilityId), reachable);
    }

    // ---------------------------------------------------------------------------------------------
    // Rule W7A-T13(b): Forge (and any Product) can invoke a capability with no provider-implementation
    // dependency. Forge consumes the AI Head over HTTP, so what it can be forced to depend on is
    // exactly the public API of the client surface: every type that surface exposes must resolve inside
    // the contract assembly or the framework, never into an implementation assembly.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void CallerSurface_ExposesNoImplementationType()
    {
        Type[] callerFacingRoots =
        [
            typeof(Nexus.Intelligence.Contracts.IAiCapabilityClient),
            typeof(Nexus.Intelligence.Contracts.AiCapabilityRequest),
            typeof(Nexus.Intelligence.Contracts.AiCapabilityResponse),
            typeof(Nexus.Intelligence.Contracts.AiCapabilityRegistration),
        ];

        var offenders = ReachableTypes(callerFacingRoots)
            .Where(IsImplementationType)
            .Select(t => $"{t.FullName} (from {t.Assembly.GetName().Name})")
            .Distinct()
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();

        Assert.True(
            offenders.Length == 0,
            "[W7A-T13(b)] A caller must not be forced to reference an AI implementation assembly to "
            + "invoke a capability. The client surface exposes implementation types. Offenders: "
            + string.Join(", ", offenders));
    }

    // Negative fixture: the implementation-type walker must flag a type that genuinely reaches into an
    // implementation assembly. Nexus.Platform.Providers.OpenAI is referenced by this test project, so
    // the foreign type is real rather than a stand-in.
    [Fact]
    public void ImplementationTypeWalker_IsNonVacuous_OnLeakyFixture()
    {
        Assert.True(
            IsImplementationType(typeof(Nexus.Platform.Providers.OpenAI.OpenAIOptions)),
            "The implementation-type detector does not recognise a provider implementation type. The "
            + "W7A-T13(b) assertion above is therefore vacuous.");

        Assert.False(
            IsImplementationType(typeof(Nexus.Intelligence.Contracts.CapabilityId)),
            "The implementation-type detector flags a contract type, so the rule can never be satisfied.");

        // The walker must descend through generics, which is where a leak is easiest to hide: a
        // Task<IReadOnlyList<ProviderOptions>> reads as framework-only to a walker that does not unwrap.
        var unwrapped = Unwrap(typeof(System.Threading.Tasks.Task<IReadOnlyList<Nexus.Platform.Providers.OpenAI.OpenAIOptions>>));
        Assert.Contains(typeof(Nexus.Platform.Providers.OpenAI.OpenAIOptions), unwrapped);
    }

    // ---------------------------------------------------------------------------------------------
    // Rule W7A-T13(c): the Platform Contract Plane contains no provider implementation semantics.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void PlatformContractPlane_DependsOnNoVendorOrProviderImplementation()
    {
        var result = Types.InAssembly(PlatformContractsAssembly)
            .ShouldNot()
            .HaveDependencyOnAny(
                "Nexus.Platform.Providers",
                "OpenAI",
                "Anthropic",
                "Azure.AI",
                "DeepSeek",
                "Mistral",
                "Ollama",
                "Google.GenerativeAI",
                "Microsoft.Extensions.AI",
                "Microsoft.SemanticKernel")
            .GetResult();

        Assert.True(
            result.IsSuccessful,
            "[W7A-T13(c)] The Platform Contract Plane (PL-04, the Nexus.Platform.Contracts assembly) must "
            + "publish provider-neutral contracts only. It must not depend on a provider implementation or "
            + "a vendor SDK. Offending types: "
            + (result.FailingTypeNames is null ? "(none)" : string.Join(", ", result.FailingTypeNames)));
    }

    // The second half of (c): no PL-04 public API may expose a provider implementation or AI-internal
    // type. PL-04 has no package or project references at all today, so this holds structurally - which
    // is exactly why it is worth locking, because the first thing that would break it is a reference
    // added for a good local reason.
    [Fact]
    public void PlatformContractPlane_ExposesNoProviderImplementationType()
    {
        var publicTypes = PlatformContractsAssembly
            .GetExportedTypes()
            .Where(t => t.Namespace is not null && t.Namespace.StartsWith("Nexus.Platform.Contracts", StringComparison.Ordinal))
            .ToArray();

        Assert.NotEmpty(publicTypes);

        var offenders = ReachableTypes(publicTypes)
            .Where(IsImplementationType)
            .Select(t => $"{t.FullName} (from {t.Assembly.GetName().Name})")
            .Distinct()
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();

        Assert.True(
            offenders.Length == 0,
            "[W7A-T13(c)] PL-04 must not expose provider implementation or AI-internal types in its public "
            + "API. Offenders: " + string.Join(", ", offenders));
    }

    // ---------------------------------------------------------------------------------------------
    // Rule W7A-T13(d): the public AI failure contract contains no vendor exception types.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void FailureContract_ExposesNoVendorExceptionType()
    {
        var failureTypes = new[]
        {
            typeof(Nexus.Intelligence.Contracts.AiFailure),
            typeof(Nexus.Intelligence.Contracts.AiFailureCategory),
            typeof(Nexus.Intelligence.Contracts.AiCapabilityException),
        };

        // No vendor type may appear in the failure contract's public API.
        var foreign = ReachableTypes(failureTypes)
            .Where(IsImplementationType)
            .Select(t => t.FullName ?? t.Name)
            .Distinct()
            .ToArray();

        Assert.True(
            foreign.Length == 0,
            "[W7A-T13(d)] The public AI failure contract must not expose a vendor type. Offenders: "
            + string.Join(", ", foreign));

        // The exception must not be able to carry a vendor exception inward. This is the mechanism by
        // which vendor exception types leak through a public API: not by being named in a signature,
        // but by being wrapped and rethrown from inside the boundary.
        var constructors = typeof(Nexus.Intelligence.Contracts.AiCapabilityException)
            .GetConstructors(BindingFlags.Public | BindingFlags.Instance);

        Assert.NotEmpty(constructors);

        var carriesInner = constructors
            .SelectMany(c => c.GetParameters())
            .Any(p => typeof(Exception).IsAssignableFrom(p.ParameterType));

        Assert.False(
            carriesInner,
            "[W7A-T13(d)] AiCapabilityException accepts an inner exception. An inner exception is how a "
            + "vendor SDK exception type reaches a caller through a public cross-Head API.");

        // Every category the directive names must be present, and none of them may name a vendor: a
        // category called OpenAIUnavailable would be a vendor type wearing a neutral name.
        var expected = new[]
        {
            "AiUnavailable", "ProviderUnavailable", "ModelUnavailable", "PolicyBlocked",
            "DataExposureBlocked", "ToolPermissionDenied", "BudgetBlocked", "Timeout",
            "InvalidOutput", "CapabilityNotFound", "HumanDecisionRequired",
        };

        var actual = Enum.GetNames<Nexus.Intelligence.Contracts.AiFailureCategory>().ToArray();

        foreach (var name in expected)
        {
            Assert.Contains(name, actual);
        }

        var vendorCategories = actual.Where(ContainsVendorName).ToArray();

        Assert.True(
            vendorCategories.Length == 0,
            "[W7A-T13(d)] A failure category names a vendor. Offenders: " + string.Join(", ", vendorCategories));
    }

    // Negative fixture: the vendor-name detector must recognise a vendor name, or every assertion built
    // on it passes by being unable to match.
    [Fact]
    public void VendorNameDetector_IsNonVacuous_OnPlantedName()
    {
        Assert.True(ContainsVendorName("OpenAIUnavailable"));
        Assert.True(ContainsVendorName("AnthropicTimeout"));
        Assert.True(ContainsVendorName("ClaudeModelUnavailable"));
        Assert.False(ContainsVendorName("ProviderUnavailable"));
        Assert.False(ContainsVendorName("ModelUnavailable"));

        // The contract assembly itself must be clean of vendor names in its public type names. The
        // dependency rule in BoundaryRuleTests covers references; this covers names, which a reference
        // rule cannot see.
        var named = ContractsAssembly.GetExportedTypes()
            .Where(t => ContainsVendorName(t.Name))
            .Select(t => t.FullName ?? t.Name)
            .ToArray();

        Assert.True(
            named.Length == 0,
            "[W7A-T13(d)] A public contract type is named after a vendor. Offenders: " + string.Join(", ", named));
    }

    // ---------------------------------------------------------------------------------------------
    // Detectors. Kept in one place so each rule's negative fixture exercises the real implementation.
    // ---------------------------------------------------------------------------------------------

    private static readonly string[] ProviderSelectingFragments =
    [
        "model", "provider", "vendor", "endpoint", "apikey", "api_key", "deployment", "baseurl",
        "base_url", "region", "gateway",
    ];

    // "Model" appears in AiExecutionResult as required evidence, and the fragment list is applied only
    // to the caller-facing roots, so the fragment is not weakened here - it is scoped at the call site.
    private static bool IsProviderSelectingName(string name)
        => ProviderSelectingFragments.Any(
            fragment => name.Contains(fragment, StringComparison.OrdinalIgnoreCase));

    private static readonly string[] VendorNames =
    [
        "openai", "anthropic", "claude", "gpt", "deepseek", "gemini", "bard", "mistral", "llama",
        "ollama", "cohere", "bedrock", "azure", "vertex",
    ];

    private static bool ContainsVendorName(string name)
        => VendorNames.Any(vendor => name.Contains(vendor, StringComparison.OrdinalIgnoreCase));

    private static bool IsImplementationType(Type type)
    {
        var assemblyName = type.Assembly.GetName().Name ?? string.Empty;

        return assemblyName.StartsWith("Nexus.Platform.Providers", StringComparison.Ordinal)
               || assemblyName.StartsWith("Nexus.Intelligence.", StringComparison.Ordinal)
               && assemblyName != "Nexus.Intelligence.Contracts"
               || assemblyName.StartsWith("Nexus.Products", StringComparison.Ordinal)
               || ContainsVendorName(assemblyName)
               || VendorNames.Any(vendor => (type.Namespace ?? string.Empty)
                   .Contains(vendor, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// Every type reachable from a set of roots through public members and generic arguments.
    /// </summary>
    /// <remarks>
    /// Descends through the contract assembly's own types so that a leak nested two records deep is
    /// still found. It does not descend into framework types, which cannot reach a Nexus type.
    /// </remarks>
    private static HashSet<Type> ReachableTypes(IEnumerable<Type> roots)
    {
        var contractAssembly = ContractsAssembly;
        var platformContractAssembly = PlatformContractsAssembly;

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

            // Only descend into Nexus contract assemblies. A framework type cannot expose a Nexus type,
            // and descending into one would pull in the whole of System.Runtime for nothing.
            var assembly = current.Assembly;
            if (assembly != contractAssembly && assembly != platformContractAssembly)
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

        foreach (var constructor in type.GetConstructors(Flags))
        {
            foreach (var parameter in constructor.GetParameters())
            {
                foreach (var unwrapped in Unwrap(parameter.ParameterType))
                {
                    yield return unwrapped;
                }
            }
        }
    }

    /// <summary>
    /// Unwraps a type to the types it carries: generic arguments, array elements and by-ref targets.
    /// </summary>
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
