using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Roles;

/// <summary>
/// The roles an estate starts with, and which model each is assigned to.
/// </summary>
/// <remarks>
/// <para>
/// <b>W7C TASK 7 (OOS-3): this is where the role seed's model identifier lives now.</b> The composition
/// root seeded the default role with a compiled-in <c>"openai:gpt-4.1"</c> literal — the same
/// hard-coded model fact as <c>OpenAIOptions.Model</c>, and the one
/// <see cref="AiRoleAssignment"/>'s own documentation already claimed was configuration: "Re-assigning
/// a role to a different model is done by upserting a new assignment for the same RoleName - swapping a
/// role's provider/model requires only a configuration change, never a code change." The type was
/// written to be configured; only the seed was not.
/// </para>
/// <para>
/// <b>An empty seed is valid and fails closed.</b> No roles means role resolution finds nothing, which
/// is the correct answer for an estate that has declared no roles, and is preferable to a built-in
/// role pointing at a model nobody chose.
/// </para>
/// </remarks>
public sealed class AiRoleSeedOptions
{
    /// <summary>The configuration section this binds to.</summary>
    public const string SectionName = "Ai:Roles";

    /// <summary>Where this seed came from, and when it was last reviewed.</summary>
    public string? Provenance { get; set; }

    /// <summary>The roles, each with its assignment.</summary>
    public List<AiRoleSeedEntry> Roles { get; set; } = [];
}

/// <summary>One seeded role and the model it is assigned to.</summary>
public sealed class AiRoleSeedEntry
{
    /// <summary>The role's name, e.g. <c>Discussion</c>.</summary>
    public string? RoleName { get; set; }

    /// <summary>What the role is for, in the operator's words.</summary>
    public string? Description { get; set; }

    /// <summary>The model that serves it.</summary>
    /// <remarks>
    /// A plain string rather than a validated registry key. A role may name a model the estate's
    /// registry does not carry — the two are separate declarations, and the disagreement is
    /// deliberately visible downstream as an assignment that resolves to no model, rather than hidden
    /// by a parse that refused one of the two files.
    /// </remarks>
    public string? ModelId { get; set; }

    /// <summary>The capabilities the role requires of that model, as <c>ModelCapabilities</c> names.</summary>
    public List<string> RequiredCapabilities { get; set; } = [];
}

/// <summary>A parsed role seed: the role, and the assignment that points it at a model.</summary>
public sealed record AiRoleSeed(AiRole Role, AiRoleAssignment Assignment);

/// <summary>
/// Parses <see cref="AiRoleSeedOptions"/> into the store's seed arguments.
/// </summary>
/// <remarks>
/// A parser rather than direct binding, for the reason the registry parser is one: the failure modes
/// here — a misspelt capability, a blank role name, one role declared twice — are all knowable before
/// the estate serves anything, and every one of them is invisible if binding is left to produce
/// defaults.
/// </remarks>
public static class AiRoleSeedParser
{
    /// <summary>Parses the seed.</summary>
    /// <param name="options">The bound configuration.</param>
    /// <param name="timeProvider">The clock for the assignment timestamps. Intended for tests.</param>
    /// <exception cref="InvalidOperationException">An entry is malformed.</exception>
    public static IReadOnlyList<AiRoleSeed> Parse(
        AiRoleSeedOptions options,
        TimeProvider? timeProvider = null)
    {
        ArgumentNullException.ThrowIfNull(options);

        if (options.Roles.Count == 0)
        {
            return [];
        }

        var clock = timeProvider ?? TimeProvider.System;
        var assignedAt = clock.GetUtcNow();
        var seeds = new List<AiRoleSeed>(options.Roles.Count);
        var seen = new HashSet<string>(StringComparer.Ordinal);

        for (var index = 0; index < options.Roles.Count; index++)
        {
            var path = $"{AiRoleSeedOptions.SectionName}:Roles[{index}]";
            var entry = options.Roles[index];

            var roleName = Required(entry.RoleName, path, "RoleName");

            // Role resolution looks a role up by name, so two entries for one name make which model
            // serves it depend on iteration order — and a role silently served by the wrong model is
            // not distinguishable from a role deliberately served by that model.
            if (!seen.Add(roleName))
            {
                throw new InvalidOperationException(
                    $"{path}: role '{roleName}' is declared more than once. Role resolution is by name, "
                    + "so a duplicate would make the assignment ambiguous.");
            }

            seeds.Add(new AiRoleSeed(
                new AiRole(roleName, Required(entry.Description, path, "Description")),
                new AiRoleAssignment(
                    roleName,
                    Required(entry.ModelId, path, "ModelId"),
                    ParseCapabilities(entry.RequiredCapabilities, path),
                    assignedAt)));
        }

        return seeds;
    }

    private static string Required(string? value, string path, string what)
        => string.IsNullOrWhiteSpace(value)
            ? throw new InvalidOperationException($"{path}: {what} is required and is missing or blank.")
            : value.Trim();

    private static ModelCapabilities ParseCapabilities(List<string> values, string path)
    {
        // Each name is validated individually for the reason recorded in the provider catalog parser:
        // a flags enum admits combinations Enum.IsDefined does not recognise, so checking the parsed
        // combination would reject every valid multi-flag value and checking nothing would store a typo
        // as a number no capability check ever matches.
        var tokens = values
            .SelectMany(value => value.Split(',', StringSplitOptions.RemoveEmptyEntries
                                             | StringSplitOptions.TrimEntries))
            .ToArray();

        if (tokens.Length == 0)
        {
            throw new InvalidOperationException(
                $"{path}: RequiredCapabilities is empty. A role that requires nothing matches any model, "
                + "including ones that cannot serve it; state the capabilities the role needs.");
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
}
