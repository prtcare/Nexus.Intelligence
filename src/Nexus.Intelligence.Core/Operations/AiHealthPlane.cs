using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Registry;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// The published health snapshot, replaced atomically, read without a lock.
/// </summary>
/// <remarks>
/// <para>
/// <b>A whole snapshot is published rather than entries updated.</b> A reader that observed entries
/// being mutated could see the first half of one probe round and the second half of the next, and
/// would route a decision against a state that never existed at any instant. Publishing a value makes
/// every read coherent by construction, and it costs one reference assignment.
/// </para>
/// <para>
/// <b>The write is a reference assignment, which is atomic in .NET.</b> No lock is needed and none is
/// taken, which matters because the read side is on the routing path and a lock there would put
/// contention in front of the gate that is supposed to be a pure function of its inputs.
/// </para>
/// </remarks>
public sealed class InMemoryAiHealthSnapshotStore : IAiHealthSnapshotStore
{
    private AiHealthSnapshot _current;

    /// <summary>Seeds the store with an initial snapshot.</summary>
    public InMemoryAiHealthSnapshotStore(AiHealthSnapshot seed)
    {
        ArgumentNullException.ThrowIfNull(seed);
        _current = seed;
    }

    /// <inheritdoc />
    public AiHealthSnapshot Current => Volatile.Read(ref _current);

    /// <inheritdoc />
    public void Publish(AiHealthSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        Volatile.Write(ref _current, snapshot);
    }
}

/// <summary>
/// The health source routing reads: a snapshot, and nothing else.
/// </summary>
/// <remarks>
/// <para>
/// <b>It replaces <c>ConfiguredAiRegistry</c> as the registered <see cref="IAiModelHealthSource"/>
/// without changing that interface, and the reason is the directive's.</b> Routing must read a
/// snapshot and must not probe inline. Keeping the synchronous two-method port and changing what
/// answers it means the router's code is unchanged in this respect — it still asks a synchronous
/// question — while what answers that question stops being a static declaration and starts being the
/// last thing the probes observed.
/// </para>
/// <para>
/// <b>It has no way to reach a provider.</b> There is no probe on this type, no probe in its
/// constructor and no probe reachable from its two methods. A future edit that wanted routing to
/// probe would have to add a dependency here, which is a visible change in a reviewed diff rather
/// than a line inside the router.
/// </para>
/// <para>
/// <b>An unpublished target answers <see cref="AiModelHealthState.Unknown"/>, which is not
/// routable.</b> That is the same reading <see cref="ConfiguredAiRegistry"/> already gives, and it is
/// deliberate: absence of evidence is not evidence of health, and a snapshot that answered
/// <see cref="AiModelHealthState.Available"/> for a target nobody probed would be asserting something
/// nobody observed.
/// </para>
/// </remarks>
public sealed class SnapshotAiHealthSource : IAiModelHealthSource
{
    private readonly IAiHealthSnapshotStore _snapshots;

    /// <summary>Reads health from a snapshot store.</summary>
    public SnapshotAiHealthSource(IAiHealthSnapshotStore snapshots)
    {
        ArgumentNullException.ThrowIfNull(snapshots);
        _snapshots = snapshots;
    }

    /// <inheritdoc />
    public AiModelHealthState GetModelHealth(string modelId, string providerId)
    {
        if (string.IsNullOrEmpty(modelId) || string.IsNullOrEmpty(providerId))
        {
            return AiModelHealthState.Unknown;
        }

        return _snapshots.Current.ModelState(modelId, providerId);
    }

    /// <inheritdoc />
    public AiModelHealthState GetProviderHealth(string providerId)
    {
        if (string.IsNullOrEmpty(providerId))
        {
            return AiModelHealthState.Unknown;
        }

        return _snapshots.Current.ProviderState(providerId);
    }
}

/// <summary>
/// Builds the snapshot an estate starts from, out of the health its configuration declares.
/// </summary>
/// <remarks>
/// <para>
/// <b>The seed is the declared state, and it is a snapshot like any other.</b> Before W7E the declared
/// health was read directly on every routing decision; now it is read once, at composition, into the
/// same shape the probes publish. There is therefore one read path in routing rather than two, and a
/// probe result and a declared state cannot be answered by different code.
/// </para>
/// <para>
/// <b>A target with no declaration gets no entry, not an entry saying available.</b> The seed records
/// what the estate said and nothing more, so a provider nobody declared is absent from the snapshot
/// and resolves to <see cref="AiModelHealthState.Unknown"/> exactly as it did before this lane.
/// </para>
/// </remarks>
public static class SeededAiHealthSnapshot
{
    /// <summary>The snapshot source marker for a snapshot built from configuration.</summary>
    public const string DeclaredSource = "declared-configuration";

    /// <summary>Builds the seed snapshot from a registry configuration.</summary>
    public static AiHealthSnapshot From(AiRegistryConfiguration configuration, DateTimeOffset takenAt)
    {
        ArgumentNullException.ThrowIfNull(configuration);

        var providers = new Dictionary<string, AiModelHealthState>(StringComparer.Ordinal);
        var models = new Dictionary<(string ModelId, string ProviderId), AiModelHealthState>();

        foreach (var entry in configuration.Health)
        {
            if (string.IsNullOrWhiteSpace(entry.ProviderId))
            {
                continue;
            }

            var providerId = entry.ProviderId.Trim();

            // A model-scoped declaration is the more specific claim and wins; a provider-wide one
            // fills in only where the model has not spoken. This is the same reading the registry
            // applies, kept in step with it by producing the snapshot the registry's own answers used
            // to be derived from.
            if (string.IsNullOrWhiteSpace(entry.ModelId))
            {
                providers[providerId] = Parsed(entry.State);
                continue;
            }

            var modelId = entry.ModelId.Trim();

            if (models.ContainsKey((modelId, providerId)))
            {
                throw new InvalidOperationException(
                    $"Health is declared more than once for model '{modelId}' on provider '{providerId}'. "
                    + "A duplicate would make the published state depend on declaration order, and the "
                    + "order is not part of the contract.");
            }

            models[(modelId, providerId)] = Parsed(entry.State);
        }

        return new AiHealthSnapshot
        {
            TakenAt = takenAt,
            Source = DeclaredSource,
            Providers = providers,
            Models = models,
        };
    }

    /// <summary>
    /// Parses a declared state, refusing an unknown name rather than defaulting it.
    /// </summary>
    /// <remarks>
    /// A misspelt state that silently became <see cref="AiModelHealthState.Unknown"/> would take a
    /// provider offline with no indication that the cause was a typo, which is the same failure
    /// <see cref="ConfiguredAiRegistry"/> already refuses at load.
    /// </remarks>
    private static AiModelHealthState Parsed(string? state)
    {
        if (string.IsNullOrWhiteSpace(state))
        {
            return AiModelHealthState.Unknown;
        }

        return ConfigurationEnum.Parse(state, AiModelHealthState.Unknown, "Health", "health state");
    }
}
