using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Models;

/// <summary>
/// Translates the contract's provider-neutral classification into the AI Head's failure vocabulary.
/// </summary>
/// <remarks>
/// <para>
/// <b>Two enumerations, one taxonomy.</b> <see cref="ModelFailureKind"/> is declared in
/// <c>Nexus.Platform.Contracts</c> because that is the contract that both sides of the provider seam
/// consume, and <c>Nexus.Platform.*</c> may not reference <c>Nexus.Intelligence.*</c> — a boundary the
/// Platform build enforces with a hard error rather than a convention. So the classification had to be
/// spelled twice, and this is the one place the two spellings meet. The correspondence is asserted
/// member-for-member, by name and by value, in
/// <c>ModelFailureKindCorrespondenceTests</c>; nothing here relies on the two being declared in the
/// same order.
/// </para>
/// <para>
/// <b>The mapping is written out rather than cast.</b> An enum-to-enum cast would compile, would be
/// correct for as long as the two declarations agreed, and would keep compiling — silently producing a
/// wrong category — the moment either side gained, lost or reordered a member. Spelling the mapping out
/// makes a drift a compile error, and it makes the translation reviewable as a translation rather than
/// as arithmetic.
/// </para>
/// </remarks>
public static class ModelFailureMap
{
    /// <summary>
    /// The AI Head's category for a classification that crossed the provider seam.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>An unclassified failure becomes <see cref="AiFailureCategory.ProviderUnavailable"/>, and that
    /// is a load-bearing choice rather than a default.</b> It is what every provider-reported failure was
    /// before the classification existed, so a caller sees exactly the category it saw before for every
    /// adapter that does not yet classify — which is the backward-compatibility half of the requirement.
    /// </para>
    /// <para>
    /// <b>It is also the only safe target of the two candidates.</b> <see cref="AiFailureCategory"/>'s
    /// own <see cref="AiFailureCategory.Unspecified"/> reads like the obvious landing place for "we do not
    /// know", and it is the wrong one: <c>IsRetryable</c> returns <see langword="false"/> for it, so an
    /// unclassified provider failure routed there would stop being failover-eligible and would stop being
    /// an <c>IsUnavailability</c> — a single missing mapping would turn a recoverable provider outage
    /// into a terminal, caller-visible policy refusal. <see cref="AiFailureCategory.ProviderUnavailable"/>
    /// is retryable and an unavailability, which is precisely what an unclassified failure of a call that
    /// was permitted must be treated as.
    /// </para>
    /// <para>
    /// The two null-ish inputs are therefore handled together, and they stay distinguishable upstream:
    /// <see langword="null"/> means the producer predates the classification, and
    /// <see cref="ModelFailureKind.Unspecified"/> means a producer classified and had no value to give.
    /// Both are recorded as such on the invocation; only their downstream category coincides.
    /// </para>
    /// </remarks>
    public static AiFailureCategory ToCategory(ModelFailureKind? kind) => kind switch
    {
        ModelFailureKind.AiUnavailable => AiFailureCategory.AiUnavailable,
        ModelFailureKind.ProviderUnavailable => AiFailureCategory.ProviderUnavailable,
        ModelFailureKind.ModelUnavailable => AiFailureCategory.ModelUnavailable,
        ModelFailureKind.PolicyBlocked => AiFailureCategory.PolicyBlocked,
        ModelFailureKind.DataExposureBlocked => AiFailureCategory.DataExposureBlocked,
        ModelFailureKind.ToolPermissionDenied => AiFailureCategory.ToolPermissionDenied,
        ModelFailureKind.BudgetBlocked => AiFailureCategory.BudgetBlocked,
        ModelFailureKind.Timeout => AiFailureCategory.Timeout,
        ModelFailureKind.InvalidOutput => AiFailureCategory.InvalidOutput,
        ModelFailureKind.CapabilityNotFound => AiFailureCategory.CapabilityNotFound,
        ModelFailureKind.HumanDecisionRequired => AiFailureCategory.HumanDecisionRequired,

        // null (no classification was produced) and Unspecified (a producer classified and found nothing)
        // both land here, for the reason the remarks give.
        _ => AiFailureCategory.ProviderUnavailable,
    };
}
