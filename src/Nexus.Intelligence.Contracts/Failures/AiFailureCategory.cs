namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The one vocabulary of AI failure that crosses a Head boundary.
/// </summary>
/// <remarks>
/// <para>
/// <b>Every failure a caller can observe is one of these values.</b> No provider exception type, no
/// SDK type and no transport type may appear in a public AI result, because a caller that can catch
/// <c>HttpRequestException</c> is a caller that knows there is a network and therefore knows there is
/// a provider. The mapping from a concrete cause to one of these values happens below the boundary,
/// in the AI Head's implementation assemblies.
/// </para>
/// <para>
/// The set is closed on purpose. A caller's recovery logic branches on these values, so adding one is
/// a contract change that consumers must be able to see; a free-form failure code would make that
/// branch unreviewable.
/// </para>
/// </remarks>
public enum AiFailureCategory
{
    /// <summary>No category applies. Never produced deliberately — if it appears, a mapping is missing.</summary>
    Unspecified = 0,

    /// <summary>The AI Head itself is not reachable or not serving. Distinct from a provider being down.</summary>
    AiUnavailable = 1,

    /// <summary>A provider is unreachable or returning transport-level failures.</summary>
    ProviderUnavailable = 2,

    /// <summary>The selected model is unavailable, retired or not served by any healthy provider.</summary>
    ModelUnavailable = 3,

    /// <summary>A governance policy refused the request. Deterministic; retrying will not change it.</summary>
    PolicyBlocked = 4,

    /// <summary>The request's data classification forbids the exposure it asked for.</summary>
    DataExposureBlocked = 5,

    /// <summary>The execution asked for a tool its profile does not permit.</summary>
    ToolPermissionDenied = 6,

    /// <summary>A cost budget would be exceeded. Deterministic for the same inputs.</summary>
    BudgetBlocked = 7,

    /// <summary>The caller's latency ceiling elapsed before an answer was produced.</summary>
    Timeout = 8,

    /// <summary>An answer was produced and rejected: it did not satisfy its required contract.</summary>
    InvalidOutput = 9,

    /// <summary>The requested capability is not registered, or is registered but disabled.</summary>
    CapabilityNotFound = 10,

    /// <summary>A human decision is required before this execution may proceed. Not a failure of the system.</summary>
    HumanDecisionRequired = 11,
}

/// <summary>Classification and retry semantics for <see cref="AiFailureCategory"/>.</summary>
public static class AiFailureCategoryExtensions
{
    /// <summary>
    /// True when the same request, unchanged, could plausibly succeed later.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Retrying belongs to the AI Head.</b> This method exists so an operator or an internal retry
    /// policy can be written against one table, not so a caller can implement its own retry loop —
    /// a caller that retries because "the model was down" is a caller that knows about providers.
    /// </para>
    /// <para>
    /// The four deterministic refusals return <see langword="false"/> deliberately. Retrying a policy
    /// block, a data-exposure block, a tool denial or a budget block is not persistence, it is the same
    /// question asked again in the hope of a different answer — and it converts a clear refusal into
    /// load.
    /// </para>
    /// </remarks>
    public static bool IsRetryable(this AiFailureCategory category) => category switch
    {
        AiFailureCategory.AiUnavailable => true,
        AiFailureCategory.ProviderUnavailable => true,
        AiFailureCategory.ModelUnavailable => true,
        AiFailureCategory.Timeout => true,
        AiFailureCategory.InvalidOutput => true,

        AiFailureCategory.PolicyBlocked => false,
        AiFailureCategory.DataExposureBlocked => false,
        AiFailureCategory.ToolPermissionDenied => false,
        AiFailureCategory.BudgetBlocked => false,
        AiFailureCategory.CapabilityNotFound => false,
        AiFailureCategory.HumanDecisionRequired => false,

        _ => false,
    };

    /// <summary>
    /// True when the category means the AI was never consulted or could not be — as opposed to having
    /// been consulted and refused.
    /// </summary>
    /// <remarks>
    /// This is the distinction an <see cref="AiDependencyClass.AiEnhanced"/> caller needs: an
    /// unavailability means "fall back visibly to the deterministic path", whereas a
    /// <see cref="AiFailureCategory.PolicyBlocked"/> means a governance decision was taken and falling
    /// back silently would conceal it. Both are failures; only one of them may be degraded past.
    /// </remarks>
    public static bool IsUnavailability(this AiFailureCategory category) => category switch
    {
        AiFailureCategory.AiUnavailable => true,
        AiFailureCategory.ProviderUnavailable => true,
        AiFailureCategory.ModelUnavailable => true,
        AiFailureCategory.Timeout => true,
        _ => false,
    };
}
