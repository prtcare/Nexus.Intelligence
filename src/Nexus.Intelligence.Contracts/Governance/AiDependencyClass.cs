namespace Nexus.Intelligence.Contracts;

/// <summary>
/// How much a feature depends on AI being available.
/// </summary>
/// <remarks>
/// <para>
/// The availability classes. The distinguishing question is the one the earlier freeze recorded:
/// <em>"if the AI Head is deleted from Nexus entirely, what happens to this operation?"</em>
/// Completes identically → <see cref="AiOptional"/>. Completes worse but correctly →
/// <see cref="AiEnhanced"/>. Does not complete → <see cref="AiDependent"/>. Cannot be permitted to
/// involve AI at all → <see cref="AiProhibited"/>.
/// </para>
/// <para>
/// The first three classes describe <b>availability</b>. They are not, and must not be read as, a
/// statement about <b>authority</b> — an <see cref="AiOptional"/> feature that lets AI output
/// influence a governance decision is still a violation of the V3 authority rule, because Platform's
/// deterministic authority is not a matter of what happens when AI is down. Authority is governed
/// separately, by the rule that AI may advise and Platform decides.
/// </para>
/// <para>
/// <see cref="AiProhibited"/> is <b>not a fourth point on that availability scale.</b> It is a
/// different axis: the first three answer "how much does this need AI?", and it answers "may AI touch
/// this at all?". The enum numbers it 3 for stability, and <b>that number must not be read as
/// severity</b> — a comparison like <c>value &gt;= AiDependent</c> is a category error. A prohibited
/// path does not depend on AI more than a dependent one; it does not depend on AI <em>at all</em>,
/// which is why <see cref="AiDependencyClassExtensions.MustSurviveAiOutage"/> is
/// <see langword="true"/> for it and <see langword="false"/> for <see cref="AiDependent"/>.
/// </para>
/// <para>
/// <b>Added at W7A.1.</b> The W7A directive named three classes and W7A implemented three, logging the
/// gap as decision <c>D-W7A-01</c> because inventing a value in a governed vocabulary is not a
/// decision an agent may take. W7A.1 carries the explicit instruction and the definition, so the gap
/// is closed by direction rather than by inference.
/// </para>
/// </remarks>
public enum AiDependencyClass
{
    /// <summary>
    /// AI is a convenience. The deterministic path is complete without it, and the operation completes
    /// normally and silently when AI is unavailable. No deterministic fallback is needed because the
    /// deterministic result <em>is</em> the result.
    /// </summary>
    AiOptional = 0,

    /// <summary>
    /// A deterministic path exists and produces a worse but correct result. The operation completes in
    /// visible degraded mode when AI is unavailable — visibly, because an unlabelled degraded result is
    /// indistinguishable from a confident wrong one.
    /// </summary>
    AiEnhanced = 1,

    /// <summary>
    /// No deterministic fallback exists. The operation cannot complete without AI, and its failure must
    /// be contained: typed, terminal and attributable, never a hang or an empty success. This is a
    /// liability that must be declared and owned, never acquired by accident.
    /// </summary>
    AiDependent = 2,

    /// <summary>
    /// <b>AI must not participate in this capability, decision, execution path or data operation.</b>
    /// </summary>
    /// <remarks>
    /// <para>
    /// Not "AI is unnecessary" — <see cref="AiOptional"/> already says that. This class says AI is
    /// <b>forbidden</b>. The deterministic path is not a fallback from AI; it is the only path, and
    /// it is the only path because a deterministic authority in Nexus has decided that AI must not be
    /// in the loop.
    /// </para>
    /// <para>
    /// A declaration of this class must name an <see cref="AiProhibitedSurface"/> — the category of
    /// protected surface that makes AI participation forbidden. The category is required because
    /// "prohibited" without a stated basis is a label, and a label is not a control.
    /// </para>
    /// </remarks>
    AiProhibited = 3,
}

/// <summary>Parsing and validation for <see cref="AiDependencyClass"/>.</summary>
public static class AiDependencyClassExtensions
{
    /// <summary>
    /// Parses a dependency class, or returns <see langword="false"/> with a reason. Unknown values are
    /// rejected, never defaulted — a defaulted class is an unclassified path, which is the condition
    /// the classification exists to eliminate.
    /// </summary>
    public static bool TryParse(string? candidate, out AiDependencyClass dependencyClass, out string? reason)
    {
        dependencyClass = default;
        reason = null;

        if (string.IsNullOrWhiteSpace(candidate))
        {
            reason = "An AI dependency class is required; it may not be omitted or empty.";
            return false;
        }

        var trimmed = candidate.Trim();
        if (!Enum.TryParse<AiDependencyClass>(trimmed, ignoreCase: true, out var parsed) || !Enum.IsDefined(parsed))
        {
            reason =
                $"'{candidate}' is not a known AI dependency class. Expected one of: " +
                string.Join(", ", Enum.GetNames<AiDependencyClass>()) + ".";
            return false;
        }

        if (char.IsDigit(trimmed[0]) || trimmed.Contains(','))
        {
            reason = $"'{candidate}' is not a known AI dependency class name. Numeric and combined values are not accepted.";
            return false;
        }

        dependencyClass = parsed;
        return true;
    }

    /// <summary>
    /// True when a feature of this class must remain usable with the AI Head absent.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The operational reading of the class, in one place. <see cref="AiDependencyClass.AiDependent"/>
    /// is the only class permitted to fail, and even it must fail cleanly.
    /// </para>
    /// <para>
    /// <see cref="AiDependencyClass.AiProhibited"/> returns <see langword="true"/>, and this is the
    /// clearest single proof that it is not a point on the availability scale. A path AI is forbidden
    /// from touching does not degrade when AI is unavailable — <b>nothing about it changes at all</b>,
    /// because AI was never in it. Reading the class as "more dependent than dependent" and returning
    /// <see langword="false"/> here would be the category error the enum's remarks warn against.
    /// </para>
    /// </remarks>
    public static bool MustSurviveAiOutage(this AiDependencyClass value)
        => value is AiDependencyClass.AiOptional
            or AiDependencyClass.AiEnhanced
            or AiDependencyClass.AiProhibited;
}
