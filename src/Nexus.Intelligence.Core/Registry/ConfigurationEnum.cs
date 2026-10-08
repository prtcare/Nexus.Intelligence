namespace Nexus.Intelligence.Core.Registry;

/// <summary>
/// Reads an enumeration member from configuration text, by name and by name only.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why this exists rather than <c>Enum.TryParse</c> plus <c>Enum.IsDefined</c>.</b> That pair is the
/// obvious way to parse an enum strictly, and it is strict about exactly one of the two hazards. It
/// refuses an out-of-range numeral — <c>"9"</c> parses to 9, <c>IsDefined(9)</c> is false, refused. It
/// does <em>not</em> refuse an in-range numeral: <c>"1"</c> parses to 1, and if any member has the
/// value 1 then <c>IsDefined(1)</c> is true and the value is accepted. The configuration said "1" and
/// the estate silently ran with whichever objective, trust tier or approval status happens to be
/// numbered 1 — a binding that succeeds and is wrong, which is the failure mode the strictness was
/// supposed to prevent.
/// </para>
/// <para>
/// Configuration has no enums, so a name is the only thing a person can meaningfully write in it, and
/// a numeral is therefore always either a mistake or an attempt to bind by position. Matching against
/// <see cref="Enum.GetNames{TEnum}"/> answers both: names bind, numerals never do, and renumbering a
/// member cannot change what a file means.
/// </para>
/// <para>
/// Case-insensitive, so <c>cheapestreliable</c> and <c>CheapestReliable</c> are the same request. That
/// is a convenience for the operator rather than a loosening: no name is a case-variant of another, so
/// there is no file whose meaning depends on casing.
/// </para>
/// </remarks>
internal static class ConfigurationEnum
{
    /// <summary>
    /// Parses a member by name, or returns <paramref name="fallback"/> when the value is absent.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// The value is present and is not the name of a member.
    /// </exception>
    internal static TEnum Parse<TEnum>(string? value, TEnum fallback, string path, string what)
        where TEnum : struct, Enum
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            // Absent is not an error here. What an absent value means is the caller's decision, which
            // is why the fallback is a parameter rather than a hardcoded default: a missing approval
            // status must mean "not approved" and a missing trust tier must mean "untrusted", and the
            // one thing those have in common is that neither is the enum's zero.
            return fallback;
        }

        var trimmed = value.Trim();

        foreach (var name in Enum.GetNames<TEnum>())
        {
            if (string.Equals(name, trimmed, StringComparison.OrdinalIgnoreCase))
            {
                return Enum.Parse<TEnum>(name);
            }
        }

        throw new InvalidOperationException(
            $"{path}: '{value}' is not a known {what}. Known values: "
            + $"{string.Join(", ", Enum.GetNames<TEnum>())}. Names are required: a numeral would bind "
            + "by position and would silently change meaning if a member were ever renumbered.");
    }
}
