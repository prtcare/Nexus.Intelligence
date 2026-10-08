using System.Reflection;
using Microsoft.AspNetCore.Routing;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Core.Models;

namespace Nexus.Intelligence.Api.Operations;

/// <summary>
/// Measures what the host actually composed, so the published read model reports evidence rather than
/// intent.
/// </summary>
/// <remarks>
/// <para>
/// <b>It reads the container, the assemblies and the route table — the three things a host knows that a
/// document does not.</b> A unit listed in a design note, a service a comment says is registered, a
/// route a README names: none of those are observable here, and the whole reason this type exists is
/// that the difference between "we intended to register it" and "the container holds it" is exactly the
/// difference this publication is for.
/// </para>
/// <para>
/// <b>It is a measurement, and every member says what it was measured from.</b> Registrations come from
/// <see cref="IServiceCollection"/> after composition; route prefixes come from the built
/// <see cref="EndpointDataSource"/>; a provider's implementation state comes from the types its
/// assembly actually declares. Nothing here is inferred from a name.
/// </para>
/// </remarks>
public static class AiRuntimeCompositionObserver
{
    /// <summary>The prefix that identifies an assembly as a provider adapter.</summary>
    private const string ProviderAssemblyPrefix = "Nexus.Platform.Providers.";

    /// <summary>The configuration path a provider's own section lives under.</summary>
    private const string ProviderConfigurationRoot = "Platform:Providers";

    /// <summary>
    /// The composition root's own registration of the probe sweep, by service type name.
    /// </summary>
    /// <remarks>
    /// The probe is registered under its concrete type as well as under
    /// <see cref="IHostedService"/>, so that "the estate runs this sweep" is answerable by asking the
    /// container rather than by re-deriving the guard the composition root applied. A registration
    /// under <see cref="IHostedService"/> alone would be indistinguishable from the other hosted
    /// service this estate composes.
    /// </remarks>
    private static readonly string HealthProbeServiceTypeName =
        typeof(AiHealthProbeService).FullName!;

    /// <summary>Observes the composition.</summary>
    /// <param name="services">The service collection, after every Add call has run.</param>
    /// <param name="configuration">The bound configuration.</param>
    /// <param name="endpoints">The built endpoint data source, or null when no route table was built.</param>
    public static AiRuntimeObservation Observe(
        IServiceCollection services,
        IConfiguration configuration,
        EndpointDataSource? endpoints)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configuration);

        var registrations = ObserveRegistrations(services);
        var providerIds = ObserveProviderIds(registrations, out var deployed);

        return new AiRuntimeObservation
        {
            HostExecutablePresent = true,
            HostName = typeof(AiRuntimeCompositionObserver).Assembly.GetName().Name ?? "Nexus.Intelligence.Api",
            HttpSurfacePresent = endpoints is not null,
            MappedApiPrefixes = ObserveApiSurfaces(endpoints),
            Registrations = registrations,
            ProviderAdapters = ObserveProviderAdapters(providerIds, deployed, registrations, configuration),

            // The health probe service BY NAME, and not "a hosted service exists". The estate does
            // register another hosted service through a dependency the AI Head does not own, so the
            // weaker test answered true on an estate whose probe sweep is not composed at all — which
            // is precisely the "implemented is not running" collapse this member exists to prevent.
            HealthProbeServiceHosted = registrations.Any(
                r => string.Equals(r.ServiceType, HealthProbeServiceTypeName, StringComparison.Ordinal)),
        };
    }

    // --- Registrations --------------------------------------------------------------------------------

    private static IReadOnlyList<AiContainerRegistration> ObserveRegistrations(IServiceCollection services)
    {
        var observed = new List<AiContainerRegistration>(services.Count);

        foreach (var descriptor in services)
        {
            var serviceType = descriptor.ServiceType;

            var implementationType = descriptor.ImplementationType
                ?? descriptor.ImplementationInstance?.GetType()
                ?? DescriptorFactoryResultType(descriptor);

            // A hosted-service registration is not a ServiceDescriptor lifetime this enum names, and
            // reporting it as Singleton would lose the one fact that matters about it.
            var lifetime = descriptor.ServiceType == typeof(IHostedService)
                ? "HostedService"
                : descriptor.Lifetime.ToString();

            observed.Add(new AiContainerRegistration(
                serviceType.FullName ?? serviceType.Name,
                implementationType?.FullName,
                lifetime,
                implementationType?.Assembly.GetName().Name ?? FactorySourceAssembly(descriptor)));
        }

        return observed;
    }

    /// <summary>
    /// The assembly a factory registration was declared in, recovered from the delegate's own type.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>A factory is not anonymous.</b> A lambda written in a composition root compiles to a closure
    /// class declared inside that root's own class, so the delegate's runtime type names the assembly
    /// that registered it. Reporting <c>(factory)</c> for every one of them — which an earlier form of
    /// this method did — makes most of a container unattributable, and the first question anyone asks
    /// about an unexpected registration is where it came from.
    /// </para>
    /// <para>
    /// The type is nullable because an instance registration genuinely has neither a factory nor a
    /// declaring assembly inside this process.
    /// </para>
    /// </remarks>
    private static string FactorySourceAssembly(ServiceDescriptor descriptor)
    {
        var assembly = descriptor.ImplementationFactory?.GetType().DeclaringType?.Assembly
            ?? descriptor.ImplementationFactory?.Method.DeclaringType?.Assembly;

        return assembly?.GetName().Name ?? "(instance)";
    }

    /// <summary>
    /// Reads the type a factory registration produces, where the factory's signature gives it away.
    /// </summary>
    /// <remarks>
    /// <c>IServiceCollection</c> keeps a factory as an opaque delegate, so a registration composed by a
    /// lambda has no declared implementation type. Some of this estate's lambdas are casts of another
    /// registration — <c>provider =&gt; (IUsageReportingModelGateway)provider.GetRequiredService&lt;IModelGateway&gt;()</c> —
    /// and for those the delegate's own return type names the implementation honestly. Where it does
    /// not, the implementation stays null rather than being guessed at.
    /// </remarks>
    private static Type? DescriptorFactoryResultType(ServiceDescriptor descriptor)
    {
        var invoke = descriptor.ImplementationFactory?.GetType().GetMethod("Invoke");

        var returnType = invoke?.ReturnType;

        return returnType is null || returnType == typeof(object)
            ? null
            : returnType;
    }

    // --- Provider adapters ----------------------------------------------------------------------------

    /// <summary>
    /// Finds every provider adapter assembly the estate holds, on two scopes.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Deployed and shipped are both inventoried, because one alone tells a misleading story.</b> The
    /// deployment's own directory answers "what could this host reach right now". The AI Head's source
    /// tree answers "what does this estate actually contain" — and it is the only scope in which
    /// <c>Nexus.Platform.Providers.Anthropic</c> appears at all, since the host's project deliberately
    /// does not reference it and its assembly never reaches the output directory.
    /// </para>
    /// <para>
    /// <b>The source tree is found by walking up for the solution file, and its absence is not an
    /// error.</b> A deployed estate has no solution file beside it; the inventory then contains exactly
    /// the deployed adapters, which is the correct answer for that estate. Every row carries its own
    /// <c>Deployed</c> flag so a reader is never left to infer which scope answered.
    /// </para>
    /// </remarks>
    private static IReadOnlyList<string> ObserveProviderIds(
        IReadOnlyList<AiContainerRegistration> registrations,
        out IReadOnlySet<string> deployed)
    {
        var assemblies = new SortedSet<string>(StringComparer.Ordinal);
        var deployedAssemblies = new HashSet<string>(StringComparer.Ordinal);

        void Consider(Assembly? assembly, bool inDeployment)
        {
            var name = assembly?.GetName().Name;

            if (name is null || !name.StartsWith(ProviderAssemblyPrefix, StringComparison.Ordinal))
            {
                return;
            }

            assemblies.Add(name);

            if (inDeployment)
            {
                deployedAssemblies.Add(name);
            }
        }

        // Scope one: what the host composes.
        foreach (var registration in registrations)
        {
            Consider(AssemblyOf(registration.SourceAssembly), inDeployment: true);
        }

        // Scope two: what the host's own assembly references, which is what its build copies out.
        foreach (var reference in typeof(AiRuntimeCompositionObserver).Assembly.GetReferencedAssemblies())
        {
            if (reference.Name is { } name && name.StartsWith(ProviderAssemblyPrefix, StringComparison.Ordinal))
            {
                assemblies.Add(name);
                deployedAssemblies.Add(name);
            }
        }

        // Scope three: the AI Head's own source tree, where it is present.
        foreach (var name in ProviderProjectsInSourceTree())
        {
            assemblies.Add(name);
        }

        deployed = deployedAssemblies;

        return [.. assemblies];
    }

    /// <summary>
    /// Provider adapter projects beside the running host, where a source tree accompanies it.
    /// </summary>
    /// <remarks>
    /// A directory's name is evidence in the same sense a file's is: <c>src/Nexus.Platform.Providers.X</c>
    /// exists or it does not, and its existence is what this reads. Nothing is read from inside it, so
    /// this cannot report a provider whose project exists but whose code was deleted — that case is
    /// caught below, where the assembly either has a serving type or does not.
    /// </remarks>
    private static IReadOnlyList<string> ProviderProjectsInSourceTree()
    {
        try
        {
            var directory = new DirectoryInfo(AppContext.BaseDirectory);

            // Six levels is enough for src/<project>/bin/<config>/<tfm>/ and stops a walk from
            // escaping to the filesystem root on an estate where no solution exists above the host.
            for (var depth = 0; directory is not null && depth < 8; depth++, directory = directory.Parent)
            {
                var source = Path.Combine(directory.FullName, "src");

                if (!Directory.Exists(source))
                {
                    continue;
                }

                return [.. Directory.GetDirectories(source, ProviderAssemblyPrefix + "*")
                    .Select(Path.GetFileName)
                    .Where(name => name is not null)
                    .Select(name => name!)
                    .Order(StringComparer.Ordinal)];
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // An unreadable directory means the shipped scope is unknown, not empty. Returning nothing
            // reports exactly the deployed adapters, which is a true statement about this host.
        }

        return [];
    }

    private static IReadOnlyList<AiProviderAdapterObservation> ObserveProviderAdapters(
        IReadOnlyList<string> providerAssemblies,
        IReadOnlySet<string> deployed,
        IReadOnlyList<AiContainerRegistration> registrations,
        IConfiguration configuration)
    {
        var observed = new List<AiProviderAdapterObservation>(providerAssemblies.Count);

        foreach (var assemblyName in providerAssemblies)
        {
            var providerId = ProviderIdOf(assemblyName);

            var assembly = AssemblyOf(assemblyName);

            var serving = assembly is null ? null : FindServingType(assembly);

            // Implemented means a type that can actually serve a completion. An assembly that declares
            // only an interface and a TODO is a Placeholder, however it is named.
            var implementation = serving is null
                ? AiProviderImplementationState.Placeholder
                : AiProviderImplementationState.Implemented;

            observed.Add(new AiProviderAdapterObservation
            {
                ProviderId = providerId,
                AssemblyName = assemblyName,
                Implementation = implementation,
                ServingTypeName = serving?.FullName,
                Deployed = deployed.Contains(assemblyName),

                // The provider's own configuration section exists AND has content. An empty section
                // that the binder created by being asked for it is not configuration.
                Configured = configuration.GetSection($"{ProviderConfigurationRoot}:{SuffixOf(assemblyName)}")
                    .GetChildren()
                    .Any(),

                // The host's own composition names something from this assembly. This is what separates
                // a provider the repository ships from one the running host could actually reach.
                RuntimeApplicable = registrations.Any(
                    r => string.Equals(r.SourceAssembly, assemblyName, StringComparison.Ordinal)),
            });
        }

        return observed;
    }

    /// <summary>The serving adapter an assembly declares, or null when it declares none.</summary>
    private static Type? FindServingType(Assembly assembly)
    {
        Type? found = null;

        try
        {
            foreach (var type in assembly.GetTypes())
            {
                if (type.IsAbstract || type.IsInterface || !type.IsClass)
                {
                    continue;
                }

                if (typeof(INamedModelGateway).IsAssignableFrom(type)
                    || typeof(IModelGateway).IsAssignableFrom(type))
                {
                    found = type;
                    break;
                }
            }
        }
        catch (ReflectionTypeLoadException ex)
        {
            // A partially loadable assembly is a real condition on a build host. The types that loaded
            // are still evidence; reporting "no adapter" because one unrelated type would not load
            // would be a wrong answer rather than an incomplete one.
            found = ex.Types
                .Where(t => t is { IsClass: true, IsAbstract: false })
                .FirstOrDefault(t => typeof(INamedModelGateway).IsAssignableFrom(t!)
                    || typeof(IModelGateway).IsAssignableFrom(t!));
        }

        return found;
    }

    /// <summary>"Nexus.Platform.Providers.OpenAI" to "openai".</summary>
    private static string ProviderIdOf(string assemblyName)
        => SuffixOf(assemblyName).ToLowerInvariant();

    private static string SuffixOf(string assemblyName)
        => assemblyName.StartsWith(ProviderAssemblyPrefix, StringComparison.Ordinal)
            ? assemblyName[ProviderAssemblyPrefix.Length..]
            : assemblyName;

    private static Assembly? AssemblyOf(string assemblyName)
    {
        try
        {
            return Assembly.Load(assemblyName);
        }
        catch (Exception ex) when (ex is FileNotFoundException or FileLoadException or BadImageFormatException)
        {
            return null;
        }
    }

    // --- API surfaces ---------------------------------------------------------------------------------

    /// <summary>Reads the mapped route prefixes out of the built route table.</summary>
    /// <remarks>
    /// The route table rather than the source: a route the code declares and a route the host maps are
    /// different facts, and only the second one is true of the estate an operator is looking at.
    /// </remarks>
    private static IReadOnlyList<AiMappedApiSurface> ObserveApiSurfaces(EndpointDataSource? endpoints)
    {
        if (endpoints is null)
        {
            return [];
        }

        var prefixes = new SortedSet<string>(StringComparer.Ordinal);

        foreach (var endpoint in endpoints.Endpoints)
        {
            if (endpoint is not RouteEndpoint route)
            {
                continue;
            }

            var text = route.RoutePattern.RawText;

            if (string.IsNullOrWhiteSpace(text))
            {
                continue;
            }

            prefixes.Add(PrefixOf(text));
        }

        return [.. prefixes.Select(prefix => new AiMappedApiSurface(prefix, KindOfSurface(prefix)))];
    }

    /// <summary>The stable prefix of a route template, with its parameters removed.</summary>
    private static string PrefixOf(string routeTemplate)
    {
        var segments = routeTemplate.Split('/', StringSplitOptions.RemoveEmptyEntries);

        var stable = new List<string>();

        foreach (var segment in segments)
        {
            if (segment.Contains('{', StringComparison.Ordinal))
            {
                break;
            }

            stable.Add(segment);
        }

        return "/" + string.Join('/', stable);
    }

    /// <summary>
    /// What a mapped surface is for.
    /// </summary>
    /// <remarks>
    /// Matched on the family rather than on the whole path, because the value reported is the route
    /// table's own literal path — which is what an operator can actually call — and a later route added
    /// under an existing family should inherit that family's kind rather than fall through to the
    /// generic one.
    /// </remarks>
    private static string KindOfSurface(string prefix) => prefix switch
    {
        _ when prefix.StartsWith("/intelligence/operations/v1", StringComparison.Ordinal) => "operator-read",
        _ when prefix.StartsWith("/intelligence/gateway/v1", StringComparison.Ordinal) => "caller",
        "/health" => "host-liveness",
        _ when prefix.StartsWith("/intelligence", StringComparison.Ordinal) => "head-api",
        _ => "host",
    };
}
