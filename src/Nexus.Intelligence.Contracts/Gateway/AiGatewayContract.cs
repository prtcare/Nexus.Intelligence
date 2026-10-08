namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The public AI Gateway contract's own identity, and the compatibility rule that governs changes to
/// it.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the contract's version, not the implementation's.</b> Before W7F the only version a
/// caller could read was the AI Head assembly's own version, served from the capabilities endpoint —
/// which meant a consumer that wanted to know whether the contract it was built against was still
/// being served had to know how the AI Head numbers its builds. Those are different numbers answering
/// different questions: an assembly version changes on every refactor, a deployment and a hotfix, and
/// a consumer that branched on it would break on a release that changed nothing it could observe. The
/// contract version below changes only when the contract does.
/// </para>
/// <para>
/// <b>The compatibility rule, stated so that it can be applied rather than interpreted.</b> Within one
/// major version the contract is <b>additive only</b>: members may be added, nullable members may gain
/// a value they previously could not hold, and enum members may be appended. Nothing is removed,
/// renamed, renumbered or narrowed, and no default changes meaning. A consumer must therefore tolerate
/// members it does not know about, and must not treat an unrecognised enum member as a failure — both
/// are what being built against a lower minor version looks like from the consumer's side, and a
/// consumer that rejected them would force every addition to be a major version, which is the same as
/// having no version strategy at all.
/// </para>
/// <para>
/// A change that removes, renames, renumbers or narrows anything, or that gives an existing member a
/// different meaning, is <b>a new major version</b>. That is a different route, served alongside the
/// old one rather than in place of it, because a consumer cannot be upgraded on the AI Head's
/// schedule: Forge and the Products each move when their own release moves, and a contract that broke
/// them in place would make every one of them a synchronised deploy.
/// </para>
/// <para>
/// <b>The WebSocket and turn-shaped surfaces are unaffected.</b> <see cref="IIntelligenceClient"/> and
/// <see cref="IntelligenceTurnRequest"/> keep the behaviour they already have; this version token
/// names the capability gateway, and a consumer of the Chat turn path is not asked to care about it.
/// </para>
/// </remarks>
public static class AiGatewayContract
{
    /// <summary>The contract's name, as it appears in a version negotiation and in a log line.</summary>
    public const string Name = "nexus.ai.gateway";

    /// <summary>
    /// The major version. <b>Incremented only for a breaking change</b>, and served alongside the
    /// version it replaces rather than in place of it.
    /// </summary>
    public const int MajorVersion = 1;

    /// <summary>
    /// The minor version. Incremented for an additive change, which a consumer built against any lower
    /// minor version of the same major version can ignore safely.
    /// </summary>
    public const int MinorVersion = 0;

    /// <summary>The version as a caller receives it, e.g. <c>1.0</c>.</summary>
    public static string Version => $"{MajorVersion}.{MinorVersion}";

    /// <summary>
    /// The path prefix every capability-gateway route is served under.
    /// </summary>
    /// <remarks>
    /// The major version appears in the path as well as in the header, deliberately and redundantly.
    /// A caller that discovers the version by negotiation uses the header; a caller that cannot or does
    /// not uses the path, and both resolve to the same contract. The alternative — one place to state
    /// it — makes the version silently ambiguous the first time a caller hard-codes a path, which is
    /// the first thing a caller does.
    /// </remarks>
    public const string RoutePrefix = "/intelligence/gateway/v1";

    /// <summary>
    /// The response header carrying <see cref="Version"/>, so a caller learns the served version from
    /// the answer to any request rather than only from a discovery call.
    /// </summary>
    /// <remarks>
    /// Stated on every capability response rather than on the discovery endpoint alone, because the
    /// failure this prevents is a caller that negotiated once at startup and never noticed a
    /// deployment underneath it. A header is also the one channel that costs the contract nothing:
    /// adding a member to a response body is a contract change with a compatibility argument, and
    /// adding a header is not.
    /// </remarks>
    public const string VersionHeader = "Nexus-Ai-Contract-Version";

    /// <summary>
    /// Whether a caller built against <paramref name="callerVersion"/> can use a gateway serving
    /// <see cref="Version"/>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Major equality is the whole rule. A caller on a lower minor version is compatible because the
    /// contract is additive within a major version; a caller on a higher minor version is compatible
    /// because it was built against a superset and every member it knows about is still served, which
    /// is the direction that makes a staged rollout of the AI Head possible.
    /// </para>
    /// <para>
    /// <b>An unparseable or absent version is not compatible.</b> Unknown is not a synonym for
    /// acceptable: the argument for tolerating a version skew rests on knowing which way the skew runs,
    /// and a caller that cannot say what it was built against is a caller whose compatibility nobody
    /// has established. The cost of the strict reading is a caller that must state its version, which
    /// is one constant.
    /// </para>
    /// </remarks>
    public static bool IsCompatibleWith(string? callerVersion)
    {
        var callerMajor = MajorOf(callerVersion);

        return callerMajor is not null && callerMajor == MajorVersion;
    }

    /// <summary>The major component of a version string, or null when it does not parse.</summary>
    /// <remarks>
    /// <para>
    /// <b>Every component must be a non-negative integer, and that strictness is the point.</b> The
    /// tempting shortcut is to read the component before the first dot and ignore the rest — which
    /// accepts <c>"1.x"</c>, <c>"1."</c> and <c>"1.0.0.0.0.0"</c> as major version 1. A caller that
    /// sent one of those has not stated a version this contract defines, and accepting it would mean the
    /// predicate answers a question nobody asked: "does this string begin with the right digit" rather
    /// than "was this caller built against a compatible contract". The two look identical on every well
    /// formed input, which is why the difference is only ever found by a caller that got it wrong and
    /// was told it was fine.
    /// </para>
    /// <para>
    /// Hand-written rather than <see cref="Version.Parse(string)"/> because this reads a token a caller
    /// supplied, and a parser that throws on malformed input would turn a version negotiation into an
    /// exception at a call site that has no business handling one. One to four components are accepted,
    /// which is exactly what <see cref="Version"/> itself round-trips, so a caller that used the
    /// framework's own type to state its version is never refused on shape.
    /// </para>
    /// </remarks>
    private static int? MajorOf(string? version)
    {
        if (version is not { Length: > 0 })
        {
            return null;
        }

        var components = version.Split('.');

        if (components.Length is < 1 or > 4)
        {
            return null;
        }

        foreach (var component in components)
        {
            if (!int.TryParse(component, out var parsed) || parsed < 0)
            {
                return null;
            }
        }

        return int.Parse(components[0]);
    }
}
