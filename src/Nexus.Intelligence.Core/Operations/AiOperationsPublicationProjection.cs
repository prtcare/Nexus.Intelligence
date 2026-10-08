using System.Globalization;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Registry;
using Nexus.Intelligence.Core.Routing;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// Builds the AI Head's published operations read model from the estate's real composition.
/// </summary>
/// <remarks>
/// <para>
/// <b>It reads ports, not files, and it derives rather than transcribes.</b> Every count this type
/// emits is computed from an object the running estate actually composed: the registry's own parse, the
/// provider catalogues' own descriptors, the health plane's own snapshot, the ledgers' own records, and
/// the host's own measurement of its container. Nothing is counted by reading configuration text, which
/// is the measurement the directive explicitly rejects — overlapping ranges and duplicate identifiers
/// make a text count a different number from the one the estate acts on.
/// </para>
/// <para>
/// <b>It is not reachable from routing, and routing is not reachable from it.</b> The projection holds
/// read ports and a configuration parse. It holds no router, no gateway and no model step, so a
/// publication cannot influence what the estate routes to — which matters because this is the one
/// component whose output leaves the AI Head's process.
/// </para>
/// <para>
/// <b>It never invokes a provider.</b> The health section reports what the health plane holds; it does
/// not probe. The directive forbids manufacturing provider activity to make a dashboard look alive, and
/// the structural way to obey that is for the publisher to have no way to call anything.
/// </para>
/// </remarks>
public sealed class AiOperationsPublicationProjection
{
    private readonly AiRegistryConfiguration _registry;
    private readonly AiOperationsConfiguration _operations;
    private readonly AiOperationsBudgetPolicy _budget;
    private readonly AiRoutingPolicy _routing;
    private readonly IModelCatalog _catalog;
    private readonly IAiHealthSnapshotStore _health;
    private readonly IAiUsageLedger _usage;
    private readonly IAiCostLedger _cost;
    private readonly AiRuntimeObservation _runtime;
    private readonly string _sourceRevision;

    /// <summary>Composes the projection from the estate's read ports.</summary>
    public AiOperationsPublicationProjection(
        AiRegistryConfiguration registry,
        AiOperationsConfiguration operations,
        AiOperationsBudgetPolicy budget,
        AiRoutingPolicy routing,
        IModelCatalog catalog,
        IAiHealthSnapshotStore health,
        IAiUsageLedger usage,
        IAiCostLedger cost,
        AiRuntimeObservation runtime,
        string sourceRevision)
    {
        ArgumentNullException.ThrowIfNull(registry);
        ArgumentNullException.ThrowIfNull(operations);
        ArgumentNullException.ThrowIfNull(budget);
        ArgumentNullException.ThrowIfNull(routing);
        ArgumentNullException.ThrowIfNull(catalog);
        ArgumentNullException.ThrowIfNull(health);
        ArgumentNullException.ThrowIfNull(usage);
        ArgumentNullException.ThrowIfNull(cost);
        ArgumentNullException.ThrowIfNull(runtime);

        _registry = registry;
        _operations = operations;
        _budget = budget;
        _routing = routing;
        _catalog = catalog;
        _health = health;
        _usage = usage;
        _cost = cost;
        _runtime = runtime;
        _sourceRevision = string.IsNullOrWhiteSpace(sourceRevision) ? "(unspecified)" : sourceRevision;
    }

    /// <summary>The source revision this projection will stamp on its envelope.</summary>
    public string SourceRevision => _sourceRevision;

    /// <summary>Projects the current state of the estate into the published payload.</summary>
    /// <remarks>
    /// Asynchronous because one of its inputs is: the provider catalogues are reached through
    /// <see cref="IModelCatalog"/>, which is asynchronous by contract. Nothing else here does I/O, and
    /// nothing here reaches a network.
    /// </remarks>
    public async Task<AiOperationsReadModelPayload> ProjectAsync(CancellationToken cancellationToken = default)
    {
        var providerSupported = await ProviderSupportedModelsAsync(cancellationToken).ConfigureAwait(false);

        var providers = BuildProviders();
        var models = BuildModels(providerSupported);
        var health = BuildHealth();

        return new AiOperationsReadModelPayload
        {
            Providers = providers,
            Models = models,
            ModelAuthority = BuildModelAuthority(models),
            Routing = BuildRouting(models),
            Runtime = BuildRuntime(),
            Health = health,
            Usage = BuildUsage(),
            Cost = BuildCost(),
            Pricing = BuildPricing(models),
            SourceGaps = BuildSourceGaps(health),
        };
    }

    // --- Surface A: the provider's own catalogue ------------------------------------------------------

    /// <summary>Reads the provider-supported models through the catalog port.</summary>
    /// <remarks>
    /// An empty query, which every source answers with everything it holds. The result is ordered by
    /// model identifier so two projections of one estate produce byte-identical documents.
    /// </remarks>
    private async Task<IReadOnlyList<ModelDescriptor>> ProviderSupportedModelsAsync(CancellationToken ct)
    {
        var descriptors = await _catalog.ListAsync(new ModelQuery(), ct).ConfigureAwait(false);

        return [.. descriptors.OrderBy(d => d.ModelId, StringComparer.Ordinal)];
    }

    // --- Providers ------------------------------------------------------------------------------------

    private IReadOnlyList<AiProviderOperationsView> BuildProviders()
    {
        // The provider universe is the union of what the registry permits and what the composition
        // contains. A provider that exists only in one of them is a real and reportable state: openai
        // is in both, anthropic is a placeholder the registry has never heard of, and a registry entry
        // with no adapter would be a registration nothing could serve.
        var adapters = _runtime.ProviderAdapters
            .ToDictionary(a => a.ProviderId, StringComparer.OrdinalIgnoreCase);

        var ids = new SortedSet<string>(StringComparer.Ordinal);

        foreach (var provider in _registry.Providers)
        {
            if (!string.IsNullOrWhiteSpace(provider.ProviderId))
            {
                ids.Add(provider.ProviderId.Trim());
            }
        }

        foreach (var adapter in _runtime.ProviderAdapters)
        {
            ids.Add(adapter.ProviderId);
        }

        var views = new List<AiProviderOperationsView>(ids.Count);

        foreach (var providerId in ids)
        {
            var declared = _registry.Providers.FirstOrDefault(
                p => string.Equals(p.ProviderId?.Trim(), providerId, StringComparison.OrdinalIgnoreCase));

            adapters.TryGetValue(providerId, out var adapter);

            var registered = declared is not null;
            var enabled = declared?.Enabled ?? false;
            var approval = ApprovalOf(declared?.Approval, $"Ai:Registry:Providers:{providerId}:Approval");

            views.Add(new AiProviderOperationsView
            {
                ProviderId = providerId,
                DisplayName = declared?.DisplayName ?? adapter?.ProviderId,
                Implementation = adapter?.Implementation ?? AiProviderImplementationState.Absent,
                Configured = adapter?.Configured ?? false,
                RegisteredForRouting = registered,
                Enabled = enabled,
                Approval = approval.ToString(),
                RoutableByConfiguration = registered
                    && enabled
                    && approval is AiGovernanceApprovalStatus.Approved
                    && (declared?.PermitsRemoteEgress ?? false),
                RuntimeApplicable = adapter?.RuntimeApplicable ?? false,
                Deployed = adapter?.Deployed ?? false,
                HealthObserved = IsObserved(providerId, modelId: null),
                HealthState = _health.Current.ProviderState(providerId).ToString(),

                // The NAME of the variable, never its value. The registry's own parse already refuses a
                // value shaped like a key, so this member cannot be carrying one.
                SecretReferenceName = declared?.SecretReference,
                PermitsRemoteEgress = declared?.PermitsRemoteEgress ?? false,

                // Both are already strings on the configuration shape — the registry parses them into
                // members only in the registration it builds. Passing them through unchanged is what
                // keeps a provider that declares neither from faulting the whole publication, which an
                // earlier form of this line did.
                Trust = declared?.Trust,
                MaxClassification = declared?.MaxClassification,
                Capabilities = [.. (declared?.Capabilities ?? []).OrderBy(c => c, StringComparer.Ordinal)],
            });
        }

        return views;
    }

    // --- Models ---------------------------------------------------------------------------------------

    private IReadOnlyList<AiModelOperationsView> BuildModels(IReadOnlyList<ModelDescriptor> providerSupported)
    {
        var catalogue = providerSupported.ToDictionary(d => d.ModelId, StringComparer.Ordinal);

        var ids = new SortedSet<string>(StringComparer.Ordinal);

        foreach (var descriptor in providerSupported)
        {
            ids.Add(descriptor.ModelId);
        }

        foreach (var model in _registry.Models)
        {
            if (!string.IsNullOrWhiteSpace(model.ModelId))
            {
                ids.Add(model.ModelId.Trim());
            }
        }

        var views = new List<AiModelOperationsView>(ids.Count);

        foreach (var modelId in ids)
        {
            catalogue.TryGetValue(modelId, out var descriptor);

            var registered = _registry.Models.FirstOrDefault(
                m => string.Equals(m.ModelId?.Trim(), modelId, StringComparison.Ordinal));

            var providerId = registered?.ProviderId ?? descriptor?.Vendor;

            var governedRegistered = registered is not null;
            var enabled = registered?.Enabled ?? false;
            var approval = ApprovalOf(registered?.Approval, $"Ai:Registry:Models:{modelId}:Approval");

            var providerEnabled = ProviderIsRoutable(providerId);

            var routable = governedRegistered
                && enabled
                && approval is AiGovernanceApprovalStatus.Approved
                && providerEnabled;

            views.Add(new AiModelOperationsView
            {
                ModelId = modelId,
                ProviderId = providerId,
                DisplayName = registered?.DisplayName,
                ProviderSupported = descriptor is not null,
                GovernedRegistered = governedRegistered,
                Classification = Classify(descriptor is not null, governedRegistered, routable),
                Enabled = enabled,
                Approval = approval.ToString(),
                // Already a string on the configuration shape. See the provider section for why it is
                // not run through ToString().
                Availability = registered?.Availability,
                RoutableByConfiguration = routable,
                Capabilities = [.. (registered?.Capabilities ?? []).OrderBy(c => c, StringComparer.Ordinal)],

                // A different vocabulary from the governed capabilities above, and read from a different
                // surface. See the contract's own remarks on why the two are never merged.
                ProviderCapabilities = descriptor is null ? [] : CapabilityNames(descriptor.Capabilities),

                ContextWindow = registered?.MaxContextTokens ?? (descriptor?.ContextWindow > 0 ? descriptor.ContextWindow : null),
                CatalogueCostPer1kIn = Money(descriptor?.CostPer1kIn),
                CatalogueCostPer1kOut = Money(descriptor?.CostPer1kOut),
            });
        }

        return views;
    }

    /// <summary>Whether a provider would permit a route, as configuration stands.</summary>
    private bool ProviderIsRoutable(string? providerId)
    {
        if (string.IsNullOrWhiteSpace(providerId))
        {
            return false;
        }

        var provider = _registry.Providers.FirstOrDefault(
            p => string.Equals(p.ProviderId?.Trim(), providerId, StringComparison.OrdinalIgnoreCase));

        return provider is not null
            && provider.Enabled
            && ApprovalOf(provider.Approval, $"Ai:Registry:Providers:{providerId}:Approval")
                is AiGovernanceApprovalStatus.Approved
            && provider.PermitsRemoteEgress;
    }

    /// <summary>
    /// Parses a declared approval status through the same helper the registry parses it with.
    /// </summary>
    /// <remarks>
    /// <b>The same helper, not a second interpretation.</b> The configuration carries the status as a
    /// name; the registry turns it into a member at load and refuses an unrecognised one. Reusing
    /// <see cref="ConfigurationEnum.Parse{TEnum}"/> here means a name this projection accepts is exactly
    /// a name the registry would have accepted, and a typo raises rather than silently reading as
    /// "unregistered" — which would report a governance decision nobody made.
    /// </remarks>
    private static AiGovernanceApprovalStatus ApprovalOf(string? declared, string path)
        => ConfigurationEnum.Parse(
            declared,
            AiGovernanceApprovalStatus.Unregistered,
            path,
            "approval status");

    private static AiModelAuthorityClassification Classify(bool providerSupported, bool governedRegistered, bool routable)
    {
        if (governedRegistered)
        {
            return routable
                ? AiModelAuthorityClassification.GovernedRoutable
                : AiModelAuthorityClassification.GovernedRegisteredNotRoutable;
        }

        // Not in the registry. A provider that supports it does not make it routable, and this is the
        // branch that carries W10.7A's decision into the published document.
        return providerSupported
            ? AiModelAuthorityClassification.ProviderSupportedNotRegisteredForRouting
            : AiModelAuthorityClassification.Undeclared;
    }

    private static AiModelAuthoritySummary BuildModelAuthority(IReadOnlyList<AiModelOperationsView> models)
        => new()
        {
            ProviderSupportedModels = models.Count(m => m.ProviderSupported),
            GovernedRegisteredModels = models.Count(m => m.GovernedRegistered),
            RoutableModels = models.Count(m => m.RoutableByConfiguration),

            // Counted, never derived by subtraction on a consumer's side. A count a consumer computes
            // and a count the producer states are two numbers that will eventually disagree.
            ProviderSupportedOnlyModels = models.Count(
                m => m.ProviderSupported && !m.GovernedRegistered),
        };

    // --- Routing --------------------------------------------------------------------------------------

    private AiRoutingInventory BuildRouting(IReadOnlyList<AiModelOperationsView> models)
    {
        var configured = models
            .Where(m => m.GovernedRegistered)
            .Select(m => new AiConfiguredRoute
            {
                ModelId = m.ModelId,
                ProviderId = m.ProviderId ?? "(unstated)",
                Eligible = m.RoutableByConfiguration,
                IneligibilityReason = m.RoutableByConfiguration ? null : IneligibilityOf(m),
            })
            .ToArray();

        // Measured from the ledger, not from the policy. A freshly composed Head has observed no
        // executions; reporting the configured fallback depth here instead would present a setting as
        // an incident, which is the substitution the directive forbids.
        var usage = _usage.Query(new AiUsageQuery());

        var executions = usage.Buckets.Sum(bucket => bucket.Executions);
        var fallbacks = usage.Buckets.Sum(bucket => bucket.FallbackExecutions);

        return new AiRoutingInventory
        {
            Objective = _routing.Objective.ToString(),
            ConfiguredFallbackDepth = _routing.FallbackDepth,
            ConfiguredRoutes = configured,
            ObservedFailover = new AiObservedFailover
            {
                ExecutionsObserved = executions > 0,
                Executions = executions,
                FallbackAttempts = fallbacks,
                ObservationSource = executions > 0
                    ? "in-process operations ledger"
                    : "none — this process has recorded no executions",
            },
            CapabilityRoutes = BuildCapabilityRoutes(models),
        };
    }

    /// <summary>Why a registered model cannot be reached, by name.</summary>
    private static string IneligibilityOf(AiModelOperationsView model)
    {
        if (!model.Enabled)
        {
            return "MODEL_DISABLED";
        }

        if (!string.Equals(model.Approval, nameof(AiGovernanceApprovalStatus.Approved), StringComparison.Ordinal))
        {
            return "MODEL_NOT_APPROVED";
        }

        return "PROVIDER_NOT_ELIGIBLE";
    }

    /// <summary>
    /// Groups registered models by the capabilities they declare, with each group's eligible count.
    /// </summary>
    /// <remarks>
    /// A capability with no candidate at all is absent from this list rather than present with zero —
    /// the estate does not enumerate the capabilities of the world, it enumerates the ones its own
    /// registry declares, and inventing the rest would be reporting an expectation as a fact.
    /// </remarks>
    private static IReadOnlyList<AiCapabilityRoute> BuildCapabilityRoutes(IReadOnlyList<AiModelOperationsView> models)
        => [.. models
            .Where(m => m.GovernedRegistered)
            .SelectMany(m => m.Capabilities.Select(capability => (capability, model: m)))
            .GroupBy(pair => pair.capability, StringComparer.Ordinal)
            .OrderBy(group => group.Key, StringComparer.Ordinal)
            .Select(group => new AiCapabilityRoute
            {
                Capability = group.Key,
                CandidateModelIds = [.. group.Select(pair => pair.model.ModelId).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal)],
                EligibleCandidates = group.Count(pair => pair.model.RoutableByConfiguration),
            })];

    // --- Runtime --------------------------------------------------------------------------------------

    private AiRuntimeInventory BuildRuntime()
    {
        var registrations = _runtime.Registrations;

        var units = new List<AiRuntimeUnit>
        {
            new()
            {
                UnitId = "api-host",
                Kind = "Host",
                Implemented = _runtime.HostExecutablePresent,
                RegisteredInContainer = false,
                ConfiguredEnabled = null,
                Hosted = _runtime.HttpSurfacePresent,

                // The host does not schedule itself; it is the thing a schedule would run inside.
                Scheduled = false,
            },
        };

        foreach (var registration in registrations.OrderBy(r => r.ServiceType, StringComparer.Ordinal))
        {
            var kind = KindOf(registration);

            if (kind is null)
            {
                continue;
            }

            units.Add(new AiRuntimeUnit
            {
                UnitId = ShortName(registration.ServiceType),
                Kind = kind,
                Implemented = true,
                RegisteredInContainer = true,
                ConfiguredEnabled = kind is "BackgroundService"
                    ? _operations.ProbeInterval is not null
                    : null,
                Hosted = kind is "BackgroundService" && _runtime.HealthProbeServiceHosted,
                Scheduled = kind is "BackgroundService",
            });
        }

        return new AiRuntimeInventory
        {
            Host = units[0],
            Units = units,

            // False, and it is a statement about the observation rather than about the estate. This
            // publisher runs inside its own process; it can report what that process composed and it
            // cannot truthfully report that a host elsewhere is running. Process-table liveness is
            // forbidden as evidence on this estate.
            RunningStateObserved = false,
            RunningStateReason =
                "This publication is projected inside the AI Head's own process. It can state what the "
                + "composition contains and what it enables; it cannot observe whether any process is "
                + "running, and process-liveness checks are not admissible evidence here.",
            Apis = [.. _runtime.MappedApiPrefixes
                .OrderBy(api => api.Prefix, StringComparer.Ordinal)
                .Select(api => new AiApiSurface
                {
                    Prefix = api.Prefix,
                    Kind = api.Kind,
                    Mapped = true,
                })],
        };
    }

    /// <summary>The runtime kind a registration represents, or null when it is not a runtime unit.</summary>
    /// <remarks>
    /// The container holds far more than runtime units — options bindings, the time provider, the
    /// registrations that exist only to be injected into one constructor. Reporting all of them as
    /// "services" would make the inventory a dump of the container rather than an answer to "what runs".
    /// </remarks>
    private static string? KindOf(AiContainerRegistration registration)
    {
        var service = ShortName(registration.ServiceType);

        if (registration.Lifetime is "HostedService")
        {
            return "BackgroundService";
        }

        if (service.StartsWith("IAi", StringComparison.Ordinal) || service.StartsWith("Ai", StringComparison.Ordinal))
        {
            return "AiComponent";
        }

        return service switch
        {
            "IModelCatalog" or "IModelGateway" or "INamedModelGateway" or "IModelCatalogSource" => "ProviderAdapter",
            "IMemoryStore" => "Store",
            "IToolCatalog" or "IToolGateway" => "ToolRegistry",
            "IContextRanker" or "IPromptAssembler" or "IContextBuilder" or "IContextRedactor" => "AiComponent",
            "IAgent" or "IAgentRegistry" or "IAgentRuntime" or "IAgentDispatcher" => "AiComponent",
            "ITurnPipeline" or "IPlanner" or "IExecutionEngine" => "AiComponent",
            "IResultReportStore" => "Store",
            _ => null,
        };
    }

    private static string ShortName(string typeName)
    {
        var index = typeName.LastIndexOf('.');
        return index >= 0 ? typeName[(index + 1)..] : typeName;
    }

    // --- Health ---------------------------------------------------------------------------------------

    private AiHealthAuthority BuildHealth()
    {
        var snapshot = _health.Current;

        var declaredSource = string.Equals(
            snapshot.Source,
            SeededAiHealthSnapshot.DeclaredSource,
            StringComparison.Ordinal);

        var providerRows = snapshot.Providers
            .OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => new AiHealthAxisRow
            {
                ProviderId = pair.Key,
                ModelId = null,
                State = pair.Value.ToString(),

                // A declared snapshot is an operator's assertion about the world. Only a snapshot whose
                // source is a probe is an observation of it.
                Observed = !declaredSource,
            })
            .ToArray();

        var modelRows = snapshot.Models
            .OrderBy(pair => pair.Key.ModelId, StringComparer.Ordinal)
            .ThenBy(pair => pair.Key.ProviderId, StringComparer.Ordinal)
            .Select(pair => new AiHealthAxisRow
            {
                ProviderId = pair.Key.ProviderId,
                ModelId = pair.Key.ModelId,
                State = pair.Value.ToString(),
                Observed = !declaredSource,
            })
            .ToArray();

        var probeConfigured = _operations.ProbeInterval is not null;

        return new AiHealthAuthority
        {
            // The host's liveness route returns a constant. It observes nothing at all — not the
            // process, not the runtime, not a dependency — and saying so is the point of the member.
            HostLiveness = AiHostLivenessBasis.Literal,
            HostLivenessImpliesRuntimeHealth = false,

            ProbeImplemented = true,
            ProbeConfiguredEnabled = probeConfigured,
            ProbeHosted = _runtime.HealthProbeServiceHosted,
            ProbeIntervalSeconds = probeConfigured
                ? (int?)_operations.ProbeInterval!.Value.TotalSeconds
                : null,

            // No IAiHealthProbe is registered anywhere in this estate's composition. The sweep is
            // composed, runs on schedule when it is enabled, and republishes the declared snapshot
            // unchanged — a visible, running, inconclusive sweep.
            ProbeCanReachProvider = false,

            SnapshotSource = snapshot.Source,
            SnapshotTakenAt = Instant(snapshot.TakenAt),
            ProviderRows = providerRows,
            ModelRows = modelRows,

            // False even where rows exist. A declared state is not an observation, and the estate has
            // no probe that could produce one.
            ProviderHealthObserved = !declaredSource,
            ModelHealthObserved = !declaredSource,
            GapId = declaredSource ? AiSourceGaps.ProviderHealth : null,
        };
    }

    /// <summary>Whether the health plane holds an <em>observed</em> state for a target.</summary>
    private bool IsObserved(string providerId, string? modelId)
    {
        var snapshot = _health.Current;

        if (string.Equals(snapshot.Source, SeededAiHealthSnapshot.DeclaredSource, StringComparison.Ordinal))
        {
            return false;
        }

        return modelId is null
            ? snapshot.Providers.ContainsKey(providerId)
            : snapshot.Models.ContainsKey((modelId, providerId));
    }

    // --- Telemetry ------------------------------------------------------------------------------------

    private AiTelemetryAvailability BuildUsage()
    {
        var report = _usage.Query(new AiUsageQuery());
        var records = report.Buckets.Sum(bucket => bucket.Executions);

        return new AiTelemetryAvailability
        {
            Axis = "usage",
            State = AiTelemetryState.InProcessOnly,

            // The ledger is a ConcurrentQueue in the AI Head's own container. Nothing writes it to a
            // disk, which is measurable rather than asserted: no type in the AI Head's source performs
            // a filesystem write.
            Durable = false,
            Store = nameof(InMemoryAiOperationsLedger),
            Scope = "AI Head process",
            RecordsHeld = records,
            Reason =
                "Usage is recorded in an in-process ledger. A record exists only for the lifetime of the "
                + "process that wrote it, so this count is zero for any fresh composition — which is a "
                + "fact about the process, not a measurement that no tokens were consumed. No durable "
                + "store exists in the AI Head, so usage must be read as unavailable rather than as zero.",
            GapId = AiSourceGaps.Usage,
        };
    }

    private AiTelemetryAvailability BuildCost()
    {
        var report = _cost.Query(new AiCostQuery());

        return new AiTelemetryAvailability
        {
            Axis = "cost",
            State = AiTelemetryState.InProcessOnly,
            Durable = false,
            Store = nameof(InMemoryAiOperationsLedger),
            Scope = "AI Head process",
            RecordsHeld = report.Entries,

            // The total the ledger can compute is deliberately NOT published. It sums
            // (AuthoritativeCost ?? 0), so an execution the estate could not price contributes zero to
            // it — a sum with an unknown part rendered as a measured spend. The count of records is a
            // fact this publication can stand behind; the total is not, so it is not here.
            Reason =
                "Cost is recorded in the same in-process ledger as usage and is subject to the same "
                + "lifetime. In addition, the ledger's own total adds zero for an unpriced execution, so "
                + "a spend figure derived from it would present an unmeasured part as a measured zero. "
                + "This publication carries the record count and no total.",
            GapId = AiSourceGaps.Cost,
        };
    }

    private AiPricingAuthority BuildPricing(IReadOnlyList<AiModelOperationsView> models)
    {
        var rated = models.Where(m => m.CatalogueCostPer1kIn is not null || m.CatalogueCostPer1kOut is not null).ToArray();

        return new AiPricingAuthority
        {
            // Read from the registry's own rate metadata rather than a second price list, so the rate an
            // operator reads here is the rate the budget gates would have used.
            Source = "Ai:Registry:Models rate metadata",
            RatesConfigured = rated.Length > 0,
            RatedModels = rated.Length,
            Currencies = [],
            OnUnpricedExecution = _budget.OnUnpricedExecution.ToString(),
        };
    }

    // --- Gaps -----------------------------------------------------------------------------------------

    private static IReadOnlyList<AiSourceGap> BuildSourceGaps(AiHealthAuthority health)
    {
        var gaps = new List<AiSourceGap>();

        if (health.GapId is { } healthGap)
        {
            gaps.Add(AiSourceGaps.Describe(healthGap));
        }

        gaps.Add(AiSourceGaps.Describe(AiSourceGaps.Usage));
        gaps.Add(AiSourceGaps.Describe(AiSourceGaps.Cost));
        gaps.Add(AiSourceGaps.Describe(AiSourceGaps.ModelUsageContract));
        gaps.Add(AiSourceGaps.Describe(AiSourceGaps.LegacyConfigurationPlane));

        return [.. gaps.OrderBy(g => g.GapId, StringComparer.Ordinal)];
    }

    // --- Formatting -----------------------------------------------------------------------------------

    /// <summary>Formats an instant the way every published document on this estate carries one.</summary>
    private static string Instant(DateTimeOffset value)
        => value.ToString("O", CultureInfo.InvariantCulture);

    /// <summary>
    /// Formats a rate as an invariant string, or null where no rate is stated.
    /// </summary>
    /// <remarks>
    /// Never <c>"0"</c> for an absent rate: a stated zero and an unstated price are different facts, and
    /// the first is a claim that a model is free.
    /// </remarks>
    private static string? Money(decimal? value)
        => value?.ToString(CultureInfo.InvariantCulture);

    /// <summary>Reads a flags enum's member names as an ordinal-ordered list.</summary>
    private static IReadOnlyList<string> CapabilityNames(ModelCapabilities capabilities)
        => capabilities is ModelCapabilities.None
            ? []
            : [.. capabilities.ToString()
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Order(StringComparer.Ordinal)];
}

/// <summary>
/// The source gaps the AI Head carries, by identifier.
/// </summary>
/// <remarks>
/// <para>
/// <b>Identifiers and one-line descriptions, in one place, because a gap is cited by name in
/// reports, in the published document and in a consumer's rendering.</b> Three spellings of one gap
/// would let a consumer's dashboard and a programme report disagree about what is missing.
/// </para>
/// <para>
/// <b>Every gap here is a measured absence, not a design note.</b> Each one is carried because a member
/// of the published document could not be populated or could not be populated durably, and the
/// publication says so rather than substituting a zero.
/// </para>
/// </remarks>
public static class AiSourceGaps
{
    /// <summary>No probe observes provider or model health; the snapshot is an operator's declaration.</summary>
    public const string ProviderHealth = "AI_PROVIDER_HEALTH_SOURCE_GAP";

    /// <summary>Usage exists only in-process, so it is unavailable outside the process that recorded it.</summary>
    public const string Usage = "AI_USAGE_SOURCE_GAP";

    /// <summary>Cost exists only in-process, and the ledger's total treats unpriced as zero.</summary>
    public const string Cost = "AI_COST_SOURCE_GAP";

    /// <summary>Platform's <c>ModelUsage</c> cannot express "the provider reported nothing".</summary>
    public const string ModelUsageContract = "MODEL_USAGE_ABSENCE_CONTRACT_DEBT";

    /// <summary>
    /// The estate carries two AI configuration planes that disagree, and only one is bound.
    /// </summary>
    /// <remarks>
    /// Read and recorded by W10.7. The legacy <c>config/*.json</c> catalogues are read by the
    /// PowerShell <c>ai-routing/</c> scripts and by nothing the AI Head host composes: they name seven
    /// providers and four models where the bound configuration names one provider and three catalogue
    /// models. Neither plane is wrong for its own consumer, and an operator reading either alone would
    /// form a different picture of the estate.
    /// </remarks>
    public const string LegacyConfigurationPlane = "AI_CONFIGURATION_PLANE_DIVERGENCE";

    /// <summary>The one-line description of a gap, by identifier.</summary>
    public static AiSourceGap Describe(string gapId) => gapId switch
    {
        ProviderHealth => new AiSourceGap
        {
            GapId = ProviderHealth,
            Summary = "No probe can observe provider or model health. The health plane's states are "
                + "declared in configuration and republished unchanged; nothing measures a provider.",
            Owner = "AI Head",
        },

        Usage => new AiSourceGap
        {
            GapId = Usage,
            Summary = "Usage is recorded only in an in-process ledger. It does not survive the process "
                + "that wrote it, so it is unavailable rather than zero.",
            Owner = "AI Head",
        },

        Cost => new AiSourceGap
        {
            GapId = Cost,
            Summary = "Cost is recorded only in the same in-process ledger, and that ledger's total "
                + "counts an unpriced execution as zero, so no spend figure is published.",
            Owner = "AI Head",
        },

        ModelUsageContract => new AiSourceGap
        {
            GapId = ModelUsageContract,
            Summary = "Nexus.Platform's ModelUsage(int,int,decimal) is non-nullable and defaults to "
                + "ModelUsage.Zero, so the Platform contract cannot carry \"the provider reported "
                + "nothing\". The AI Head works around it out of band; the contract itself is unchanged.",
            Owner = "Nexus Platform",
        },

        LegacyConfigurationPlane => new AiSourceGap
        {
            GapId = LegacyConfigurationPlane,
            Summary = "Two AI configuration planes exist and disagree. config/*.json (seven providers, "
                + "four models) is read only by the PowerShell ai-routing scripts; the bound "
                + "appsettings.json (one provider, three catalogue models) is what the AI Head host "
                + "composes. Neither is reconciled with the other.",
            Owner = "AI Head / Forge",
        },

        _ => new AiSourceGap
        {
            GapId = gapId,
            Summary = "A gap recorded without a description. This is a defect in the publisher.",
            Owner = "AI Head",
        },
    };
}
