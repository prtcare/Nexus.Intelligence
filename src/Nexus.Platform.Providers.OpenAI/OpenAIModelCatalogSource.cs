using Microsoft.Extensions.Options;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Core.Models;

namespace Nexus.Platform.Providers.OpenAI;

/// <summary>
/// Reports the models this adapter serves, as configured.
/// </summary>
/// <remarks>
/// <para>
/// <b>W7C TASK 7 (OOS-3): the descriptor list moved out of this file.</b> It was a
/// <c>static readonly ModelDescriptor[]</c> and it was the last place in the estate where a model
/// identifier was compiled in as a fact — including <c>openai:gpt-4.1</c>, the recorded hard-coded
/// default. The list now comes from <see cref="OpenAICatalogOptions"/>. This class constructs
/// descriptors; it does not decide which models exist.
/// </para>
/// <para>
/// <b>Parsed in the constructor, so a malformed catalog fails at composition.</b> Same reasoning as
/// the estate's own registry parser: a capability name that is not a member, or a vendor left blank,
/// is knowable before the estate serves anything, and discovering it as a role that mysteriously fails
/// to resolve points the investigation at the wrong file.
/// </para>
/// <para>
/// <b>An empty catalog reports no models and that is not a defect.</b> It means the deployment has
/// declared none, and everything downstream then fails closed. A source that substituted a built-in
/// default here would reintroduce exactly the code-level model fact this change removes.
/// </para>
/// </remarks>
public sealed class OpenAIModelCatalogSource : IModelCatalogSource
{
    private readonly IReadOnlyList<ModelDescriptor> _descriptors;

    /// <summary>Builds the descriptor list from configuration.</summary>
    /// <exception cref="InvalidOperationException">
    /// An entry is malformed. The message names the offending entry.
    /// </exception>
    public OpenAIModelCatalogSource(IOptions<OpenAICatalogOptions> options)
    {
        ArgumentNullException.ThrowIfNull(options);

        _descriptors = Build(options.Value);
    }

    /// <inheritdoc />
    public Task<IReadOnlyList<ModelDescriptor>> ListAsync(CancellationToken ct = default)
        => Task.FromResult(_descriptors);

    // --- Parsing ------------------------------------------------------------------------------------

    private static IReadOnlyList<ModelDescriptor> Build(OpenAICatalogOptions options)
    {
        var entries = options.Models;

        if (entries.Count == 0)
        {
            return [];
        }

        var descriptors = new List<ModelDescriptor>(entries.Count);
        var seen = new HashSet<string>(StringComparer.Ordinal);

        for (var index = 0; index < entries.Count; index++)
        {
            var path = $"{OpenAICatalogOptions.SectionName}:Models[{index}]";

            var modelId = Required(entries[index].ModelId, path, "ModelId");
            var vendor = Required(entries[index].Vendor, path, "Vendor");

            // A duplicate identifier does not merely duplicate a row: ModelQuery matching walks this
            // list, so two entries for one id make "which descriptor answers for this model" depend on
            // position, and a price or window read from the wrong one is invisible.
            if (!seen.Add(modelId))
            {
                throw new InvalidOperationException(
                    $"{path}: model '{modelId}' is declared more than once in this provider's catalog.");
            }

            var entry = entries[index];
            var contextWindow = entry.ContextWindow;

            if (contextWindow <= 0)
            {
                throw new InvalidOperationException(
                    $"{path}: ContextWindow is {contextWindow}. A model declaring no context window cannot "
                    + "satisfy a context requirement, so the entry would be listed and never selected.");
            }

            descriptors.Add(new ModelDescriptor(
                modelId,
                vendor,
                ParseCapabilities(entry.Capabilities, path),
                contextWindow,
                entry.CostPer1kIn,
                entry.CostPer1kOut,
                ParseLatency(entry.Latency, path)));
        }

        return descriptors;
    }

    private static string Required(string? value, string path, string what)
        => string.IsNullOrWhiteSpace(value)
            ? throw new InvalidOperationException($"{path}: {what} is required and is missing or blank.")
            : value.Trim();

    private static ModelCapabilities ParseCapabilities(List<string> values, string path)
    {
        // One string may carry a comma-separated flag list, which is how a flags enum is normally
        // written in configuration. Splitting is what lets each NAME be validated: Enum.TryParse would
        // accept the whole combination, and Enum.IsDefined would reject every valid multi-flag value.
        var tokens = values
            .SelectMany(value => value.Split(',', StringSplitOptions.RemoveEmptyEntries
                                             | StringSplitOptions.TrimEntries))
            .ToArray();

        if (tokens.Length == 0)
        {
            throw new InvalidOperationException(
                $"{path}: Capabilities is empty. A descriptor declaring no capabilities matches no "
                + "ModelQuery, so it would be configured and never used.");
        }

        var capabilities = default(ModelCapabilities);

        foreach (var token in tokens)
        {
            if (!Enum.TryParse<ModelCapabilities>(token, ignoreCase: true, out var parsed)
                || !Enum.IsDefined(parsed))
            {
                throw new InvalidOperationException(
                    $"{path}: '{token}' is not a known capability. Known values: "
                    + $"{string.Join(", ", Enum.GetNames<ModelCapabilities>())}.");
            }

            capabilities |= parsed;
        }

        return capabilities;
    }

    private static LatencyClass ParseLatency(string? value, string path)
    {
        // Required rather than defaulted. A missing latency that silently became Medium would make every
        // unpriced-by-latency model claim to be average, and the routing score reads this class.
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException(
                $"{path}: Latency is required. Known values: "
                + $"{string.Join(", ", Enum.GetNames<LatencyClass>())}.");
        }

        if (!Enum.TryParse<LatencyClass>(value, ignoreCase: true, out var parsed) || !Enum.IsDefined(parsed))
        {
            throw new InvalidOperationException(
                $"{path}: '{value}' is not a known latency class. Known values: "
                + $"{string.Join(", ", Enum.GetNames<LatencyClass>())}.");
        }

        return parsed;
    }
}
