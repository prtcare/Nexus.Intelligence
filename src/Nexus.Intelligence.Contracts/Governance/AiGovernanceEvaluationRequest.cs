namespace Nexus.Intelligence.Contracts;

/// <summary>
/// Everything AI Governance is asked to decide about one proposed execution.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the AI Head's internal evaluation input, not a caller's contract.</b> It carries the
/// provider, model, agent and prompt the AI Head has <em>selected</em>, because the governance question
/// is whether a selection already made may proceed. It is emphatically not a surface through which a
/// caller states a preference: nothing here reaches a caller, and the caller-facing
/// <see cref="AiCapabilityRequest"/> has no field capable of expressing any of it. A caller that could
/// populate this type would be a caller selecting its own provider, which is the thing the whole
/// boundary exists to prevent.
/// </para>
/// <para>
/// The distinction matters for review. When an auditor asks "why was this model used?", the answer is
/// that the model registry selected it and this record shows governance permitted it — not that a
/// caller asked for it.
/// </para>
/// </remarks>
public sealed record AiGovernanceEvaluationRequest
{
    /// <summary>The caller's request identifier, for correlation with the audit record.</summary>
    public required string RequestId { get; init; }

    /// <summary>What was asked for.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>Who asked.</summary>
    public required AiRequesterIdentity Requester { get; init; }

    /// <summary>The classification of the request as submitted. The gate for exposure.</summary>
    public required DataClassification Classification { get; init; }

    /// <summary>The classifications of the context supplied. Used for the ceiling and for scope checks.</summary>
    public IReadOnlyList<DataClassification> ContextClassifications { get; init; } = [];

    /// <summary>Where the execution would physically happen.</summary>
    public AiDestinationClass Destination { get; init; } = AiDestinationClass.Local;

    /// <summary>The caller's execution policy: ceilings, quality requirement and degradation preference.</summary>
    public AiExecutionPolicy Execution { get; init; } = AiExecutionPolicy.Default;

    /// <summary>What the caller permits the execution to do.</summary>
    public ToolPermissionProfile Tools { get; init; } = ToolPermissionProfile.None;

    /// <summary>The tool identifiers the execution intends to invoke.</summary>
    public IReadOnlyList<string> RequestedToolIds { get; init; } = [];

    /// <summary>The model the registry selected. Governance decides whether it may serve.</summary>
    public string? ModelId { get; init; }

    /// <summary>The provider that serves <see cref="ModelId"/>, as the registry states it.</summary>
    public string? ProviderId { get; init; }

    /// <summary>The agent selected to act, where an agent is involved.</summary>
    public string? AgentId { get; init; }

    /// <summary>The prompt or instruction set to be applied.</summary>
    public string? PromptId { get; init; }

    /// <summary>The prompt version to be applied.</summary>
    public string? PromptVersion { get; init; }

    /// <summary>
    /// The estimated cost of the execution, where one is known before it runs.
    /// </summary>
    /// <remarks>
    /// An estimate and not a measurement: this gate runs before the provider call, so the only cost
    /// that can be known is a prediction. That is sufficient for a ceiling — refusing an execution
    /// predicted to exceed a budget is the point of having one — and it is why
    /// <see cref="AiCost.IsEstimated"/> exists on the post-execution record.
    /// </remarks>
    public decimal? EstimatedCost { get; init; }

    /// <summary>Correlates the decision with the request and with the AI Head's audit record.</summary>
    public required string CorrelationId { get; init; }

    /// <summary>
    /// A protected surface this execution would touch, if the caller can identify one.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Declared by the AI Head, which knows what it is about to do. Two of the six surfaces are refused
    /// unconditionally when named — <see cref="AiProhibitedSurface.PlatformGovernanceAuthority"/> and
    /// <see cref="AiProhibitedSurface.ProtectedGitMergeAuthority"/> — and the remainder are refused
    /// through the prohibition register, so naming one can only ever refuse more.
    /// </para>
    /// <para>
    /// This is a declaration and not a detector. The engine cannot infer that an execution is about to
    /// merge a protected branch; the prohibition register exists so that the surfaces are declared
    /// <em>somewhere</em>, and this field is the per-request half of that. A request that sits on a
    /// prohibited surface and does not say so is a defect in the caller, and the negative fixtures
    /// record it as one.
    /// </para>
    /// </remarks>
    public AiProhibitedSurface? TouchesSurface { get; init; }

    /// <summary>A short, caller-safe description of what this execution is for, for the decision record.</summary>
    public string? Purpose { get; init; }
}
