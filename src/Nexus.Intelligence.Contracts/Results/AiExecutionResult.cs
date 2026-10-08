namespace Nexus.Intelligence.Contracts;

/// <summary>How an AI execution ended.</summary>
public enum AiExecutionStatus
{
    /// <summary>The capability was served and the output satisfies its response contract.</summary>
    Succeeded = 0,

    /// <summary>An answer was produced but the caller's quality requirement was only partly met.</summary>
    PartiallySucceeded = 1,

    /// <summary>
    /// The deterministic path was taken instead: AI was unavailable or refused. Explicit, because a
    /// degraded result that is not labelled is indistinguishable from a confident wrong one.
    /// </summary>
    Degraded = 2,

    /// <summary>The execution failed. <see cref="AiExecutionResult.Failure"/> carries the category.</summary>
    Failed = 3,

    /// <summary>A policy refused the execution before any model was consulted.</summary>
    Blocked = 4,

    /// <summary>Execution is waiting on a human decision. Terminal until a human acts.</summary>
    PendingHumanDecision = 5,
}

/// <summary>What a policy decided about an execution.</summary>
public sealed record AiPolicyDecision
{
    /// <summary>True when the execution was permitted to proceed.</summary>
    public required bool Allowed { get; init; }

    /// <summary>The policy rules that produced this decision, by stable identifier.</summary>
    public IReadOnlyList<string> RulesApplied { get; init; } = [];

    /// <summary>Why, in caller-safe terms. Populated when <see cref="Allowed"/> is false.</summary>
    public string? Reason { get; init; }

    /// <summary>True when the decision was taken by a human rather than by policy.</summary>
    public bool HumanDecided { get; init; }

    /// <summary>An allowed decision with no rules applied, used when no policy is configured.</summary>
    public static AiPolicyDecision AllowedByDefault { get; } = new() { Allowed = true };

    /// <summary>A refusal.</summary>
    public static AiPolicyDecision Denied(string reason, params string[] rules) => new()
    {
        Allowed = false,
        Reason = reason,
        RulesApplied = rules,
    };
}

/// <summary>What evaluation concluded about an output, where evaluation ran at all.</summary>
/// <remarks>
/// <see cref="NotEvaluated"/> is a first-class outcome, not an absence. Most executions are not
/// evaluated, and conflating "not checked" with "checked and passed" would make an unevaluated output
/// indistinguishable from a verified one — the same defect as an unlabelled degraded result.
/// </remarks>
public sealed record AiEvaluationResult
{
    /// <summary>Whether evaluation ran, and what it concluded.</summary>
    public required AiEvaluationVerdict Verdict { get; init; }

    /// <summary>The evaluator that ran, by identifier. Absent when nothing ran.</summary>
    public string? EvaluatorId { get; init; }

    /// <summary>Caller-safe notes from the evaluator.</summary>
    public IReadOnlyList<string> Notes { get; init; } = [];

    /// <summary>Nothing ran. The default.</summary>
    public static AiEvaluationResult NotEvaluated { get; } = new() { Verdict = AiEvaluationVerdict.NotEvaluated };
}

/// <summary>The outcome of evaluating an AI output.</summary>
public enum AiEvaluationVerdict
{
    /// <summary>No evaluator ran. Not the same as passing.</summary>
    NotEvaluated = 0,

    /// <summary>An evaluator ran and passed the output.</summary>
    Passed = 1,

    /// <summary>An evaluator ran and failed the output.</summary>
    Failed = 2,

    /// <summary>An evaluator ran and could not conclude.</summary>
    Inconclusive = 3,
}

/// <summary>Token and unit consumption for one execution.</summary>
public sealed record AiTokenUsage
{
    /// <summary>
    /// Input tokens consumed, or <c>null</c> when the provider reported no usage.
    /// </summary>
    /// <remarks>
    /// <b>Null is not zero.</b> A caller reading <c>null</c> is being told the estate has no measurement;
    /// a caller reading <c>0</c> is being told the execution consumed no tokens. Serving the first as
    /// the second would state a measurement nobody made. This is the caller-facing end of the same
    /// distinction <c>AiUsageEntry.TokensIn</c> carries.
    /// </remarks>
    public int? InputTokens { get; init; }

    /// <summary>Output tokens produced, or <c>null</c> when the provider reported no usage.</summary>
    /// <remarks>See <see cref="InputTokens"/>.</remarks>
    public int? OutputTokens { get; init; }

    /// <summary>Input tokens served from a provider-side cache, where the provider reports them.</summary>
    public int? CachedInputTokens { get; init; }

    /// <summary>Non-token units consumed, e.g. images or audio seconds. Named by <see cref="UnitName"/>.</summary>
    public decimal? OtherUnits { get; init; }

    /// <summary>What <see cref="OtherUnits"/> counts, e.g. <c>image</c>. Absent when no other units were used.</summary>
    public string? UnitName { get; init; }

    /// <summary>No usage was recorded for this execution.</summary>
    /// <remarks>
    /// Both counts are null rather than zero: "nothing was recorded" and "nothing was consumed" are
    /// different facts, and only the second is a measurement.
    /// </remarks>
    public static AiTokenUsage None { get; } = new();
}

/// <summary>What an execution cost, and whether the figure is measured or estimated.</summary>
public sealed record AiCost
{
    /// <summary>The amount.</summary>
    public required decimal Amount { get; init; }

    /// <summary>ISO 4217 currency of <see cref="Amount"/>.</summary>
    public required string Currency { get; init; }

    /// <summary>
    /// True when the amount is derived from a price catalogue rather than reported by the provider.
    /// </summary>
    /// <remarks>
    /// Carried explicitly because the two are not interchangeable: an estimated cost is a prediction
    /// that a budget decision may rest on, and a reader must be able to tell which it is holding. The
    /// AI Head already distinguishes the two through its usage source.
    /// </remarks>
    public bool IsEstimated { get; init; } = true;

    /// <summary>Zero cost, for executions that did not reach a provider.</summary>
    public static AiCost Zero(string currency = "USD") => new() { Amount = 0m, Currency = currency, IsEstimated = false };
}

/// <summary>How long an execution took, broken down where the AI Head can attribute it.</summary>
public sealed record AiTiming
{
    /// <summary>Total elapsed time for the execution as the caller experiences it.</summary>
    public required TimeSpan Total { get; init; }

    /// <summary>Time spent inside provider calls, where attributable.</summary>
    public TimeSpan? Provider { get; init; }

    /// <summary>Time spent waiting before the first provider attempt, e.g. on policy or context assembly.</summary>
    public TimeSpan? PreExecution { get; init; }
}

/// <summary>
/// The AI Head's record of one execution: what was asked, what happened, what it produced, what it
/// cost, and how it was governed.
/// </summary>
/// <remarks>
/// <para>
/// <b>The AI Head's internal record, not the caller's contract.</b> It states which provider and
/// model served the execution because an operator and an auditor must be able to answer that question
/// under authority. The caller does not receive this type: it receives
/// <see cref="AiCapabilityResponse"/>, in which provider and model are replaced by an opaque
/// <see cref="AiExecutionReference"/>. Keeping the two shapes distinct is what lets the AI Head change
/// provider without any consumer observing it — a caller that can read <see cref="ModelUsed"/> is a
/// caller that will eventually branch on it.
/// </para>
/// <para>
/// Provider and model appear here as <b>evidence of what happened</b>. No field on this record was
/// supplied by the caller as a preference, and none may be.
/// </para>
/// </remarks>
public sealed record AiExecutionResult
{
    /// <summary>The caller's request identifier, echoed for correlation.</summary>
    public required string RequestId { get; init; }

    /// <summary>The AI Head's identifier for this execution.</summary>
    public required string ExecutionId { get; init; }

    /// <summary>The capability that was requested.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>How the execution ended.</summary>
    public required AiExecutionStatus Status { get; init; }

    /// <summary>The unstructured output, where the response contract asked for one.</summary>
    public string? Output { get; init; }

    /// <summary>The structured output, where the response contract asked for one.</summary>
    public string? StructuredOutput { get; init; }

    /// <summary>Sources the output cites, where the capability produces citations.</summary>
    public IReadOnlyList<Citation> Citations { get; init; } = [];

    /// <summary>Which provider served the execution. Evidence, never instruction.</summary>
    public string? ProviderUsed { get; init; }

    /// <summary>Which model served the execution. Evidence, never instruction.</summary>
    public string? ModelUsed { get; init; }

    /// <summary>Tokens and units consumed.</summary>
    public AiTokenUsage Usage { get; init; } = AiTokenUsage.None;

    /// <summary>What the execution cost.</summary>
    public AiCost? Cost { get; init; }

    /// <summary>How long it took.</summary>
    public AiTiming? Timing { get; init; }

    /// <summary>What policy decided.</summary>
    public AiPolicyDecision? PolicyDecision { get; init; }

    /// <summary>What evaluation concluded, where evaluation ran.</summary>
    public AiEvaluationResult Evaluation { get; init; } = AiEvaluationResult.NotEvaluated;

    /// <summary>The typed failure, present exactly when <see cref="Status"/> is a failing status.</summary>
    public AiFailure? Failure { get; init; }

    /// <summary>The opaque reference the caller receives in place of provider and model identity.</summary>
    public required AiExecutionReference Execution { get; init; }

    /// <summary>The audit record reference for this execution.</summary>
    public required string AuditReference { get; init; }

    /// <summary>The version of the prompt or instruction set applied, for audit and reproduction.</summary>
    public string? PromptVersion { get; init; }

    /// <summary>Tools the execution actually invoked, by identifier.</summary>
    public IReadOnlyList<string> ToolsInvoked { get; init; } = [];
}
