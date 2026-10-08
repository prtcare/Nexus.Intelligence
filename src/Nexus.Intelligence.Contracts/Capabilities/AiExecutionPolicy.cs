namespace Nexus.Intelligence.Contracts;

/// <summary>
/// What the caller requires of the execution: how long it may take, what it may cost, how good the
/// answer must be, and whether a degraded answer is acceptable at all.
/// </summary>
/// <remarks>
/// <para>
/// The policies here are <b>ceilings and requirements supplied by the caller</b>. How they are met —
/// which provider, which model, how many attempts, in what order — is the AI Head's business and is
/// not expressible here. There is no field by which a caller may prefer, pin or exclude a model.
/// </para>
/// <para>
/// <see cref="LatencyBudget"/> is a ceiling on the <em>whole</em> operation, not on one provider
/// attempt. The AI Head's internal retry and failover budget is a subdivision of it and must stop
/// short of it, because retrying past the caller's ceiling converts a bounded degradation into a
/// caller-visible timeout.
/// </para>
/// </remarks>
public sealed record AiExecutionPolicy
{
    /// <summary>
    /// The caller's ceiling on total elapsed time. <see langword="null"/> means "no caller ceiling",
    /// which is not the same as "unbounded": the AI Head still applies its own default. A caller that
    /// cannot state a ceiling is a caller that has not decided what its user should experience.
    /// </summary>
    public TimeSpan? LatencyBudget { get; init; }

    /// <summary>Maximum acceptable cost for this request, in <see cref="CostCurrency"/>.</summary>
    public decimal? MaxCost { get; init; }

    /// <summary>ISO 4217 currency for <see cref="MaxCost"/>. Required when <see cref="MaxCost"/> is set.</summary>
    public string? CostCurrency { get; init; }

    /// <summary>The least acceptable outcome. Below this, the AI Head must fail rather than answer.</summary>
    public required AiQualityRequirement Quality { get; init; }

    /// <summary>
    /// What the caller wants to happen when the capability cannot be served at the required quality.
    /// </summary>
    /// <remarks>
    /// This field is where the AI dependency classification becomes operational. An
    /// <see cref="AiDependencyClass.AiOptional"/> caller says <see cref="AiDegradationPreference.
    /// ReturnDeterministicResult"/>; an <see cref="AiDependencyClass.AiDependent"/> caller says
    /// <see cref="AiDegradationPreference.Fail"/> and accepts that the operation cannot complete.
    /// The two are the same request with different honest answers.
    /// </remarks>
    public AiDegradationPreference OnDegradation { get; init; } = AiDegradationPreference.ReturnDeterministicResult;

    /// <summary>An execution policy that states no ceiling but requires a complete answer.</summary>
    public static AiExecutionPolicy Default { get; } = new() { Quality = AiQualityRequirement.Complete };
}

/// <summary>What a caller will accept when the ideal path is unavailable.</summary>
public enum AiDegradationPreference
{
    /// <summary>Hand back the caller's own deterministic result. AI absence is swallowed, silently or near-silently.</summary>
    ReturnDeterministicResult = 0,

    /// <summary>Hand back a worse-but-correct result, explicitly labelled as degraded.</summary>
    ReturnLabelledDegradedResult = 1,

    /// <summary>Fail with a typed failure. There is no deterministic fallback and the caller knows it.</summary>
    Fail = 2,
}

/// <summary>The least acceptable answer, expressed as requirements rather than as a score.</summary>
/// <remarks>
/// Deliberately not a numeric confidence threshold. A model-reported confidence is not comparable
/// across providers or even across prompts, so a threshold on it would be a number that looks like a
/// control and is not one. These are structural requirements the AI Head can actually check.
/// </remarks>
public sealed record AiQualityRequirement
{
    /// <summary>True when every factual claim in the output must carry a <see cref="Citation"/>.</summary>
    public bool RequireCitations { get; init; }

    /// <summary>True when the output must satisfy <see cref="AiResponseContract.OutputSchemaJson"/>.</summary>
    public bool RequireStructuredOutput { get; init; }

    /// <summary>
    /// The minimum number of citations required when <see cref="RequireCitations"/> is set. Zero means
    /// "at least one"; a value greater than zero is an explicit floor.
    /// </summary>
    public int MinimumCitations { get; init; }

    /// <summary>True when an answer that cannot meet these requirements must fail rather than degrade.</summary>
    public bool Strict { get; init; }

    /// <summary>No structural requirement beyond an answer being produced.</summary>
    public static AiQualityRequirement Complete { get; } = new();

    /// <summary>Every claim cited; used by review-shaped capabilities.</summary>
    public static AiQualityRequirement Cited { get; } = new() { RequireCitations = true, MinimumCitations = 1 };

    /// <summary>Output must match the declared schema or the execution fails.</summary>
    public static AiQualityRequirement Structured { get; } =
        new() { RequireStructuredOutput = true, Strict = true };
}
