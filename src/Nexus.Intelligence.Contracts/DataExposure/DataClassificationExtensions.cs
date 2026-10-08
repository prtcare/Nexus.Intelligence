namespace Nexus.Intelligence.Contracts;

/// <summary>Ordering and strict parsing for <see cref="DataClassification"/>.</summary>
public static class DataClassificationExtensions
{
    /// <summary>The most sensitive classification Nexus defines. Nothing may raise above it.</summary>
    public const DataClassification MostSensitive = DataClassification.Secret;

    /// <summary>
    /// Parses a classification name, or returns <see langword="false"/> with a reason.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Unknown classifications are rejected, never defaulted.</b> This is the difference between a
    /// controlled vocabulary and a configuration typo that silently downgrades protection: a caller
    /// that sends <c>"customerdata"</c> (no separator) or <c>"Restricted"</c> (the retired V2 value)
    /// must be told it is wrong, not quietly given <see cref="DataClassification.Internal"/>.
    /// </para>
    /// <para>
    /// Matching is case-insensitive because the value crosses a JSON boundary where casing is not
    /// semantically meaningful, but it is <b>not</b> fuzzy: it must be one of the eight defined names
    /// exactly. Numeric input is rejected — <c>7</c> is not a classification, it is a number that
    /// happens to be in range, and accepting it would let an off-by-one in a caller become a silently
    /// mislabelled payload.
    /// </para>
    /// </remarks>
    public static bool TryParse(string? candidate, out DataClassification classification, out string? reason)
    {
        classification = default;
        reason = null;

        if (string.IsNullOrWhiteSpace(candidate))
        {
            reason = "A data classification is required; it may not be omitted or empty.";
            return false;
        }

        var trimmed = candidate.Trim();
        if (!Enum.TryParse<DataClassification>(trimmed, ignoreCase: true, out var parsed) ||
            !Enum.IsDefined(parsed))
        {
            reason =
                $"'{candidate}' is not a known data classification. Expected one of: " +
                string.Join(", ", Enum.GetNames<DataClassification>()) +
                ". (Numeric values are not accepted.)";
            return false;
        }

        // Enum.TryParse accepts "7" and "Public, Internal"; guard against both.
        if (char.IsDigit(trimmed[0]) || trimmed.Contains(','))
        {
            reason = $"'{candidate}' is not a known data classification name. Numeric and combined values are not accepted.";
            return false;
        }

        classification = parsed;
        return true;
    }

    /// <summary>Parses a classification name or throws <see cref="FormatException"/>.</summary>
    public static DataClassification Parse(string candidate)
        => TryParse(candidate, out var parsed, out var reason) ? parsed : throw new FormatException(reason);

    /// <summary>True when <paramref name="value"/> is one of the eight defined classifications.</summary>
    public static bool IsDefined(string? value) => TryParse(value, out _, out _);

    /// <summary>
    /// True when <paramref name="value"/> is at least as sensitive as <paramref name="floor"/>.
    /// </summary>
    /// <remarks>
    /// This is the comparison a data-exposure policy needs and the reason the enum is ordered. It is
    /// expressed as a method rather than left to callers so that the ordering assumption lives in one
    /// place.
    /// </remarks>
    public static bool IsAtLeast(this DataClassification value, DataClassification floor) => value >= floor;

    /// <summary>The more sensitive of two classifications.</summary>
    public static DataClassification Max(DataClassification left, DataClassification right)
        => left >= right ? left : right;

    /// <summary>
    /// The classification of a bundle of items: the most sensitive of them.
    /// </summary>
    /// <remarks>
    /// A bundle is as sensitive as its most sensitive member. An empty sequence is
    /// <see cref="DataClassification.Public"/> — there is nothing to protect, and returning something
    /// more sensitive would make every request that carries no context look risky, which is how a
    /// control gets ignored.
    /// </remarks>
    public static DataClassification Aggregate(IEnumerable<DataClassification> classifications)
    {
        ArgumentNullException.ThrowIfNull(classifications);

        var result = DataClassification.Public;
        var any = false;
        foreach (var item in classifications)
        {
            any = true;
            result = Max(result, item);
        }

        return any ? result : DataClassification.Public;
    }

    /// <summary>True when the classification denotes material that must never be persisted in an audit record.</summary>
    public static bool IsNeverPersistable(this DataClassification value)
        => value == DataClassification.Secret;
}
