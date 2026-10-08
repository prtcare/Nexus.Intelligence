using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Registry;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// Runs the configured probes over the declared inventory and publishes one snapshot.
/// </summary>
/// <remarks>
/// <para>
/// <b>It reads the declared inventory from configuration rather than asking the routing registry to
/// enumerate itself.</b> <see cref="IAiModelRegistry"/> deliberately offers no enumeration — its own
/// contract says a registry that can be asked to materialise everything will eventually be asked on a
/// hot path — and a probe sweep over the whole estate is exactly the kind of inventory-wide question
/// that boundary exists to keep off the routing port. The configuration is the declared inventory,
/// which is what a sweep needs, and it is not a hot path.
/// </para>
/// <para>
/// <b>Nothing here is reachable from a routing decision.</b> The router holds an
/// <see cref="IAiModelHealthSource"/>, which reads a snapshot; it does not hold this type, and this
/// type is not reachable from anything the router holds. That is the structural half of "no inline
/// probing", and a test asserts the behavioural half by counting probe invocations across a routing
/// call.
/// </para>
/// <para>
/// <b>A probe that throws, or that cannot conclude, leaves the previous state in place.</b> Treating
/// a probe crash as unavailability would let a broken monitoring component take the estate's
/// providers offline — the failure mode where the observability plane becomes the outage.
/// </para>
/// <para>
/// <b>With no probe configured, this publishes the declared snapshot unchanged.</b> That is the
/// committed estate's composition, and it is why every deterministic test in this lane runs without
/// a provider credential: the estate ships no probe that would need one.
/// </para>
/// </remarks>
public sealed class ConfiguredAiHealthProbeRunner : IAiHealthProbeRunner
{
    private readonly AiRegistryConfiguration _configuration;
    private readonly IReadOnlyList<IAiHealthProbe> _probes;
    private readonly IAiHealthSnapshotStore _store;
    private readonly TimeProvider _time;

    /// <summary>Builds a runner over the declared inventory and the configured probes.</summary>
    public ConfiguredAiHealthProbeRunner(
        AiRegistryConfiguration configuration,
        IEnumerable<IAiHealthProbe> probes,
        IAiHealthSnapshotStore store,
        TimeProvider time)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(probes);
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(time);

        _configuration = configuration;

        // Ordered by probe identifier so that two runs over the same estate select the same probe for
        // a target. A runner whose choice depended on registration order would make a health state
        // depend on composition order, which nothing records.
        _probes = [.. probes.OrderBy(probe => probe.ProbeId, StringComparer.Ordinal)];
        _store = store;
        _time = time;
    }

    /// <inheritdoc />
    public async Task<AiHealthSnapshot> RunOnceAsync(CancellationToken cancellationToken = default)
    {
        var previous = _store.Current;
        var now = _time.GetUtcNow();

        var providers = new Dictionary<string, AiModelHealthState>(previous.Providers, StringComparer.Ordinal);
        var models = new Dictionary<(string ModelId, string ProviderId), AiModelHealthState>(previous.Models);
        var observedAt = new Dictionary<string, DateTimeOffset>(previous.ProviderObservedAt, StringComparer.Ordinal);
        var sources = new SortedSet<string>(StringComparer.Ordinal);

        foreach (var providerId in DeclaredProviderIds())
        {
            var target = new AiHealthProbeTarget { ProviderId = providerId };

            var observation = await ObserveAsync(target, cancellationToken).ConfigureAwait(false);

            if (observation is null)
            {
                sources.Add("not-probed");
                continue;
            }

            sources.Add(observation.ProbeId);

            if (observation.HasState)
            {
                providers[providerId] = observation.State!.Value;
                observedAt[providerId] = observation.ObservedAt;
            }
        }

        foreach (var (modelId, providerId) in DeclaredModelTargets())
        {
            var target = new AiHealthProbeTarget { ProviderId = providerId, ModelId = modelId };

            var observation = await ObserveAsync(target, cancellationToken).ConfigureAwait(false);

            if (observation is null)
            {
                sources.Add("not-probed");
                continue;
            }

            sources.Add(observation.ProbeId);

            if (observation.HasState)
            {
                models[(modelId, providerId)] = observation.State!.Value;
            }
        }

        var snapshot = new AiHealthSnapshot
        {
            TakenAt = now,
            Source = sources.Count == 0 ? "no-targets" : string.Join(',', sources),
            Providers = providers,
            Models = models,
            ProviderObservedAt = observedAt,
        };

        _store.Publish(snapshot);
        return snapshot;
    }

    /// <summary>
    /// Finds a probe for a target and runs it, converting every failure into "no answer".
    /// </summary>
    /// <remarks>
    /// The exception is swallowed rather than propagated and rather than recorded as a state. A probe
    /// that throws has told the estate nothing about the provider; recording it as unavailable would
    /// be the runner inventing a finding, and recording it as available would be the runner inventing
    /// a worse one.
    /// </remarks>
    private async Task<AiHealthObservation?> ObserveAsync(
        AiHealthProbeTarget target, CancellationToken cancellationToken)
    {
        var probe = _probes.FirstOrDefault(candidate => candidate.Handles(target));

        if (probe is null)
        {
            return null;
        }

        try
        {
            var observation = await probe.ProbeAsync(target, cancellationToken).ConfigureAwait(false);

            return observation is { Outcome: AiHealthProbeOutcome.Observed, State: not null }
                ? observation
                : null;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            // Deliberately swallowed: a monitoring component that throws must not be able to take a
            // provider offline by doing so. The previous state stands.
            return null;
        }
    }

    /// <summary>The declared provider identifiers, in ordinal order.</summary>
    /// <remarks>
    /// Ordinal order rather than declaration order, so that a reordered configuration file cannot
    /// change the order probes run in — and, where two probes could both handle a target, cannot
    /// change which one the runner would have picked had the ordering rule been different.
    /// </remarks>
    private IEnumerable<string> DeclaredProviderIds() => _configuration.Providers
        .Select(entry => entry.ProviderId)
        .Where(providerId => !string.IsNullOrWhiteSpace(providerId))
        .Select(providerId => providerId!.Trim())
        .Distinct(StringComparer.Ordinal)
        .OrderBy(providerId => providerId, StringComparer.Ordinal);

    /// <summary>The declared model targets, in ordinal order.</summary>
    private IEnumerable<(string ModelId, string ProviderId)> DeclaredModelTargets()
    {
        var seen = new HashSet<(string, string)>();

        foreach (var entry in _configuration.Models
            .OrderBy(entry => entry.ModelId, StringComparer.Ordinal)
            .ThenBy(entry => entry.ProviderId, StringComparer.Ordinal))
        {
            if (string.IsNullOrWhiteSpace(entry.ModelId) || string.IsNullOrWhiteSpace(entry.ProviderId))
            {
                continue;
            }

            var target = (entry.ModelId.Trim(), entry.ProviderId.Trim());

            if (seen.Add(target))
            {
                yield return target;
            }
        }
    }
}
