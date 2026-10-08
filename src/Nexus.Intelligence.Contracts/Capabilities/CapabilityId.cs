using System.Text.Json.Serialization;

namespace Nexus.Intelligence.Contracts;

/// <summary>
/// A semantic capability identifier: <c>&lt;domain&gt;.&lt;object&gt;</c>, lowercase, dot-separated.
/// </summary>
/// <remarks>
/// <para>
/// This is the whole point of the V3 AI boundary. A caller asks for <em>what work</em> it wants
/// done — <c>architecture.review</c>, <c>code.review</c> — and never for <em>who should do it</em>.
/// Provider and model selection are the AI Head's business (V3 principle 11), and nothing in this
/// type or in <see cref="AiCapabilityRequest"/> can express them.
/// </para>
/// <para>
/// It is a validated <b>string</b> and deliberately not a C# enum. A capability is a governed,
/// registerable, independently versioned thing; an enum would make adding one a compile-time event
/// that forces every consumer of this package to rebuild. The registry
/// (<see cref="AiCapabilityRegister"/>) is data, so the membership can grow without a new assembly.
/// </para>
/// <para>
/// The format carries no version, no vendor and no product name. The dot count is not fixed at one:
/// <c>code.review</c> and <c>business.invoice.analyze</c> are both valid, because the domain
/// vocabulary is expected to deepen and a two-segment ceiling would force a rename later — and the
/// rename would be a wire break.
/// </para>
/// <para>
/// "No version" is enforced rather than merely stated: a segment that is a run of digits, or
/// <c>v</c> followed by a run of digits, is refused. A versioned capability identifier is version
/// pinning under another name — a caller that pins <c>v2</c> has pinned the one thing the boundary
/// exists to let the AI Head change.
/// </para>
/// </remarks>
/// <remarks>
/// The converter is applied here rather than left to each consumer to register, because the type
/// cannot be read without it and a consumer that forgot would discover that at the far end of a
/// boundary rather than at compile time. See <see cref="CapabilityIdJsonConverter"/>.
/// </remarks>
[JsonConverter(typeof(CapabilityIdJsonConverter))]
public sealed record CapabilityId
{
    /// <summary>Maximum accepted length. Long enough for a five-segment id, short enough to bound a log line.</summary>
    public const int MaxLength = 96;

    private CapabilityId(string value) => Value = value;

    /// <summary>The canonical, lowercase, dot-separated identifier.</summary>
    public string Value { get; }

    /// <summary>
    /// Parses a capability identifier, or returns <see langword="false"/> with a reason.
    /// </summary>
    /// <remarks>
    /// Validation is strict on purpose. A capability identifier is a key in a governed register, so
    /// an identifier that differs only by case or by a trailing space from a registered one is a
    /// defect, not a coincidence to be normalised away: normalising would make two spellings resolve
    /// to one capability, and the audit record would then be unable to say which the caller sent.
    /// </remarks>
    public static bool TryParse(string? candidate, out CapabilityId? capabilityId, out string? reason)
    {
        capabilityId = null;
        reason = null;

        if (string.IsNullOrWhiteSpace(candidate))
        {
            reason = "A capability identifier is required.";
            return false;
        }

        if (candidate.Length > MaxLength)
        {
            reason = $"A capability identifier may not exceed {MaxLength} characters (received {candidate.Length}).";
            return false;
        }

        if (candidate != candidate.Trim())
        {
            reason = "A capability identifier may not have leading or trailing whitespace.";
            return false;
        }

        if (candidate != candidate.ToLowerInvariant())
        {
            reason = "A capability identifier must be lowercase.";
            return false;
        }

        var segments = candidate.Split('.');
        if (segments.Length < 2)
        {
            reason = "A capability identifier must have at least two dot-separated segments, e.g. 'code.review'.";
            return false;
        }

        foreach (var segment in segments)
        {
            if (segment.Length == 0)
            {
                reason = "A capability identifier may not contain an empty segment.";
                return false;
            }

            foreach (var c in segment)
            {
                if (c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-')
                {
                    continue;
                }

                reason = $"A capability identifier segment may contain only a-z, 0-9 and '-'; '{segment}' contains '{c}'.";
                return false;
            }

            if (IsVersionSegment(segment))
            {
                reason =
                    $"A capability identifier segment may not be a version marker; '{candidate}' contains " +
                    $"'{segment}'. A versioned capability identifier is version pinning under another name: it " +
                    "lets a caller hold the thing that changes when the AI Head changes how the work is done.";
                return false;
            }
        }

        capabilityId = new CapabilityId(candidate);
        return true;
    }

    /// <summary>
    /// True when a segment is a version marker rather than vocabulary: <c>v1</c>, <c>v2</c>, <c>1</c>.
    /// </summary>
    /// <remarks>
    /// A segment of digits, or of <c>v</c> followed by digits, is a version and nothing else — no
    /// domain vocabulary is spelled that way. Banning it by shape is what keeps the "no version in a
    /// capability identifier" rule enforceable: without it, <c>code.review.v2</c> parses, and a caller
    /// that pins <c>v2</c> has pinned the implementation detail the boundary exists to hide.
    /// </remarks>
    private static bool IsVersionSegment(string segment)
    {
        if (segment.Length == 0)
        {
            return false;
        }

        var digits = segment[0] == 'v' ? segment.AsSpan(1) : segment.AsSpan();

        if (digits.Length == 0)
        {
            return false;
        }

        foreach (var c in digits)
        {
            if (c is < '0' or > '9')
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>Parses a capability identifier or throws <see cref="FormatException"/>.</summary>
    public static CapabilityId Parse(string candidate)
        => TryParse(candidate, out var parsed, out var reason)
            ? parsed!
            : throw new FormatException(reason);

    /// <summary>True when <paramref name="value"/> is a well-formed capability identifier.</summary>
    public static bool IsValid(string? value) => TryParse(value, out _, out _);

    /// <summary>
    /// A stable, deterministic token suitable for use as a metric or registry key. Two spellings of
    /// the same identifier cannot produce different tokens, because invalid identifiers have no token.
    /// </summary>
    public string ToToken() => Value;

    public override string ToString() => Value;
}
