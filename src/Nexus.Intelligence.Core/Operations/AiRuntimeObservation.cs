using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// What the host observed about its own composition, measured rather than asserted.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why this type exists rather than the projection reading the composition itself.</b> Core is a
/// library: it holds no container, no service collection and no assembly list, and giving it one would
/// make it unable to be tested without a host. The host is the thing that <em>knows</em> what it
/// composed, so the host measures its own composition and hands the measurement in. The projection then
/// reasons over evidence rather than over its own assumptions about what a host probably builds.
/// </para>
/// <para>
/// <b>Every member is an observation, and each says what it was observed from.</b> A runtime inventory
/// assembled from a hand-written list is a wish; this one is assembled from the container's actual
/// service descriptors, the assemblies actually loaded, and the configuration sections actually bound.
/// </para>
/// </remarks>
public sealed record AiRuntimeObservation
{
    /// <summary>Whether the composition includes an executable host.</summary>
    public required bool HostExecutablePresent { get; init; }

    /// <summary>The host's own name, for the document to name what it was published from.</summary>
    public required string HostName { get; init; }

    /// <summary>
    /// Whether the host maps an HTTP surface at all.
    /// </summary>
    /// <remarks>
    /// A publication can be produced by a host that never listens. Reporting this separately from
    /// <see cref="MappedApiPrefixes"/> keeps "no APIs" distinguishable from "APIs exist and none are
    /// mapped", which are different estates.
    /// </remarks>
    public required bool HttpSurfacePresent { get; init; }

    /// <summary>The route prefixes the host's route table actually maps, ordinal-ordered.</summary>
    public required IReadOnlyList<AiMappedApiSurface> MappedApiPrefixes { get; init; }

    /// <summary>
    /// The container's registrations, as observed from the built service collection.
    /// </summary>
    /// <remarks>
    /// <b>The service collection and not a document.</b> A unit listed in a design note is not a unit
    /// the host registers, and the whole point of this member is that the difference is measurable.
    /// </remarks>
    public required IReadOnlyList<AiContainerRegistration> Registrations { get; init; }

    /// <summary>The provider adapters the composition contains, at every implementation state.</summary>
    public required IReadOnlyList<AiProviderAdapterObservation> ProviderAdapters { get; init; }

    /// <summary>Whether the health-probe background service is registered hosted.</summary>
    public required bool HealthProbeServiceHosted { get; init; }
}

/// <summary>One route prefix the host maps.</summary>
public sealed record AiMappedApiSurface(string Prefix, string Kind);

/// <summary>One container registration, as observed.</summary>
/// <remarks>
/// The implementation type is nullable because a factory or instance registration genuinely has none,
/// and reporting a guess there would turn "composed by a lambda" into a type name nobody wrote.
/// </remarks>
public sealed record AiContainerRegistration(
    string ServiceType,
    string? ImplementationType,
    string Lifetime,
    string SourceAssembly);

/// <summary>One provider adapter the composition contains.</summary>
/// <remarks>
/// <para>
/// <b>Observed from the code and the configuration, not from the registry.</b> The registry says which
/// providers are <em>permitted</em>; this says which ones <em>exist</em>. Keeping them in separate
/// records is what lets the published document report a provider that is implemented and not
/// registered — <c>anthropic</c> — instead of silently omitting it, which would make the estate's own
/// placeholder invisible.
/// </para>
/// </remarks>
public sealed record AiProviderAdapterObservation
{
    /// <summary>The provider identifier derived from the adapter's identity.</summary>
    public required string ProviderId { get; init; }

    /// <summary>The assembly the adapter lives in.</summary>
    public required string AssemblyName { get; init; }

    /// <summary>What actually exists: an adapter, a placeholder, or nothing.</summary>
    public required AiProviderImplementationState Implementation { get; init; }

    /// <summary>The serving type, where one exists. Null for a placeholder.</summary>
    public string? ServingTypeName { get; init; }

    /// <summary>The provider's own configuration section is present and bound.</summary>
    public required bool Configured { get; init; }

    /// <summary>The host's composition root composes this adapter into the container.</summary>
    public required bool RuntimeApplicable { get; init; }

    /// <summary>
    /// The adapter's assembly is in the host's own deployment closure.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>A third axis, because "the estate ships it" and "the host runs it" are different claims.</b>
    /// <c>Nexus.Platform.Providers.Anthropic</c> exists in this repository's source and is built by its
    /// solution; the host's project deliberately does not reference it, so the assembly is not in the
    /// host's output directory at all. A reader told only "anthropic: placeholder" would reasonably ask
    /// why an operator cannot simply enable it; this member is the answer, and omitting the row entirely
    /// would be worse — an absence reads as "no such adapter was ever written", which is false.
    /// </para>
    /// <para>
    /// False also for a provider the host does not deploy but does register, which is a configuration
    /// defect an operator would want surfaced rather than smoothed over.
    /// </para>
    /// </remarks>
    public required bool Deployed { get; init; }
}
