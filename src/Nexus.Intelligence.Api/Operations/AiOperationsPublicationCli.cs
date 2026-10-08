using System.Globalization;
using System.Reflection;
using System.Text.Json;
using Microsoft.AspNetCore.Routing;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Registry;
using Nexus.Intelligence.Core.Routing;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Api.Operations;

/// <summary>
/// The host's publication entry point: project the estate and write the operations read model.
/// </summary>
/// <remarks>
/// <para>
/// <b>It lives in the host rather than in a separate tool, and that is the whole design.</b> A separate
/// publisher would compose its own container and would therefore be a second composition root — a
/// publisher that could report an estate the host does not run. Running inside the host's own
/// <c>Program</c> means the document is projected from the container the estate actually serves from,
/// which is the only way the published facts and the running facts can be guaranteed to be the same.
/// </para>
/// <para>
/// <b>It publishes and exits without ever listening.</b> The route table is built and observed before
/// this runs, so the API surface inventory is real, and no socket is opened. A publication must never
/// be the reason an estate started serving.
/// </para>
/// </remarks>
public static class AiOperationsPublicationCli
{
    /// <summary>The verb that selects this mode.</summary>
    public const string Verb = "publish-operations";

    /// <summary>Whether the host was invoked to publish rather than to serve.</summary>
    public static bool IsInvocation(string[] args)
        => args.Length > 0 && string.Equals(args[0], Verb, StringComparison.Ordinal);

    /// <summary>Runs the publication and returns the process exit code.</summary>
    public static async Task<int> RunAsync(
        IServiceCollection collection,
        IServiceProvider services,
        IConfiguration configuration,
        EndpointDataSource? endpoints,
        string[] args,
        TextWriter output)
    {
        ArgumentNullException.ThrowIfNull(collection);
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(output);

        if (!TryParse(args, out var options, out var usageRefusal))
        {
            await output.WriteLineAsync(usageRefusal).ConfigureAwait(false);
            return 2;
        }

        // An explicit --observed-at is supported so that a proof can re-publish over a fixed instant and
        // show the digest unchanged. Otherwise the clock is read here, once, at the top of the run.
        var observedAt = options.ObservedAt ?? DateTimeOffset.UtcNow;

        var revision = options.Revision ?? RevisionOf(typeof(AiOperationsPublicationCli).Assembly);

        AiOperationsPublicationProjection projection;

        try
        {
            projection = Compose(collection, services, configuration, endpoints, revision);
        }
        catch (Exception ex)
        {
            await output.WriteLineAsync($"AUTHORITY_UNAVAILABLE — the AI Head could not be composed: {ex.Message}")
                .ConfigureAwait(false);
            return 3;
        }

        var publisher = new AiOperationsReadPublisher(projection);

        var outcome = await publisher.PublishAsync(options.Destination!, observedAt).ConfigureAwait(false);

        await output.WriteLineAsync(Report(options, observedAt, revision, outcome)).ConfigureAwait(false);

        if (outcome.Published)
        {
            return 0;
        }

        return outcome.Reason.StartsWith("AUTHORITY_UNAVAILABLE", StringComparison.Ordinal)
            ? 3
            : outcome.Reason.Contains("destination", StringComparison.OrdinalIgnoreCase)
                ? 5
                : 4;
    }

    /// <summary>Composes the projection from the host's own container and configuration.</summary>
    /// <remarks>
    /// Every dependency is resolved from the container the host built, so the projection reads the same
    /// objects the running estate routes with. The two registry-shaped inputs are re-read from
    /// configuration rather than resolved, because the runtime ports deliberately offer no enumeration —
    /// asking the routing registry to materialise itself is the boundary the estate draws against
    /// inventory-wide questions on a hot path.
    /// </remarks>
    private static AiOperationsPublicationProjection Compose(
        IServiceCollection collection,
        IServiceProvider services,
        IConfiguration configuration,
        EndpointDataSource? endpoints,
        string revision)
    {
        var registryConfiguration =
            configuration.GetSection(AiRegistryConfiguration.SectionName).Get<AiRegistryConfiguration>()
            ?? new AiRegistryConfiguration();

        var operationsConfiguration =
            configuration.GetSection(AiOperationsConfiguration.SectionName).Get<AiOperationsConfiguration>()
            ?? new AiOperationsConfiguration();

        var observation = AiRuntimeCompositionObserver.Observe(collection, configuration, endpoints);

        return new AiOperationsPublicationProjection(
            registryConfiguration,
            operationsConfiguration,
            operationsConfiguration.BudgetPolicy(),
            AiRoutingPolicy.From(registryConfiguration.Routing),
            services.GetRequiredService<IModelCatalog>(),
            services.GetRequiredService<IAiHealthSnapshotStore>(),
            services.GetRequiredService<IAiUsageLedger>(),
            services.GetRequiredService<IAiCostLedger>(),
            observation,
            revision);
    }

    // --- Arguments ------------------------------------------------------------------------------------

    private sealed record PublicationOptions(
        string? Destination,
        string? Revision,
        DateTimeOffset? ObservedAt);

    private static bool TryParse(string[] args, out PublicationOptions options, out string refusal)
    {
        options = new PublicationOptions(null, null, null);
        refusal = string.Empty;

        for (var index = 1; index < args.Length; index++)
        {
            var argument = args[index];

            switch (argument)
            {
                case "--out":
                    if (++index >= args.Length)
                    {
                        refusal = "usage: publish-operations --out <absolute-directory> "
                            + "[--revision <sha>] [--observed-at <iso-8601>]";
                        return false;
                    }

                    options = options with { Destination = args[index] };
                    break;

                case "--revision":
                    if (++index >= args.Length)
                    {
                        refusal = "usage: publish-operations --out <absolute-directory> "
                            + "[--revision <sha>] [--observed-at <iso-8601>]";
                        return false;
                    }

                    options = options with { Revision = args[index] };
                    break;

                case "--observed-at":
                    if (++index >= args.Length
                        || !DateTimeOffset.TryParse(
                            args[index],
                            CultureInfo.InvariantCulture,
                            DateTimeStyles.RoundtripKind,
                            out var parsed))
                    {
                        refusal = "--observed-at requires an ISO-8601 instant.";
                        return false;
                    }

                    options = options with { ObservedAt = parsed };
                    break;

                default:
                    refusal = $"unrecognised argument '{argument}'. "
                        + "usage: publish-operations --out <absolute-directory> [--revision <sha>] "
                        + "[--observed-at <iso-8601>]";
                    return false;
            }
        }

        if (string.IsNullOrWhiteSpace(options.Destination))
        {
            refusal = "usage: publish-operations --out <absolute-directory> is required. The published "
                + "location is a governed decision and is never guessed.";
            return false;
        }

        return true;
    }

    /// <summary>The build's own revision, where the SDK stamped one into the assembly.</summary>
    private static string RevisionOf(Assembly assembly)
    {
        var informational = assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;

        if (string.IsNullOrWhiteSpace(informational))
        {
            return "(unspecified)";
        }

        // The SDK writes "1.2.3+<commit>". The commit is the revision; the version is not.
        var plus = informational.IndexOf('+', StringComparison.Ordinal);

        return plus >= 0 && plus < informational.Length - 1
            ? informational[(plus + 1)..]
            : informational;
    }

    /// <summary>A machine-readable one-line report, so evidence can be collected without parsing prose.</summary>
    private static string Report(
        PublicationOptions options,
        DateTimeOffset observedAt,
        string revision,
        AiOperationsPublishOutcome outcome)
        => JsonSerializer.Serialize(new
        {
            published = outcome.Published,
            path = outcome.Path,
            payloadDigest = outcome.PayloadDigest,
            reason = outcome.Reason,
            sourceRevision = revision,
            observedAt = observedAt.ToString("O", CultureInfo.InvariantCulture),
            contract = AiOperationsReadContract.SchemaVersion,
            authority = AiOperationsReadContract.Authority,
            destination = options.Destination,
            schemaVersion = AiOperationsReadContract.SchemaVersion,
            fileName = AiOperationsReadContract.DocumentFileName,
        }, AiOperationsJson.Canonical);
}
