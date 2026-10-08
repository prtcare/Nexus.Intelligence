namespace Nexus.Intelligence.Contracts;

/// <summary>
/// A typed AI failure. This is the only failure shape that may cross a Head boundary.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="Message"/> is a <b>caller-safe</b> description written by the AI Head. It is not a
/// provider error body and must never be one: an upstream message can carry a model name, an
/// endpoint, a region or a request id, any of which re-leaks what the boundary exists to contain.
/// The raw cause is retained for operators through <see cref="AuditReference"/>, not through this
/// record.
/// </para>
/// <para>
/// There is no <c>InnerException</c>, no stack trace and no provider payload on this type, and none
/// may be added.
/// </para>
/// </remarks>
public sealed record AiFailure
{
    /// <summary>The failure classification. The field callers branch on.</summary>
    public required AiFailureCategory Category { get; init; }

    /// <summary>A stable, machine-readable code within the category, e.g. <c>provider_health_unusable</c>.</summary>
    public required string Code { get; init; }

    /// <summary>A caller-safe message. Never a provider error body.</summary>
    public required string Message { get; init; }

    /// <summary>Optional caller-safe guidance, e.g. what the caller may do instead.</summary>
    public string? Remedy { get; init; }

    /// <summary>True when the same request could plausibly succeed later.</summary>
    public bool Retryable { get; init; }

    /// <summary>True when a human must act before the capability can be served.</summary>
    public bool RequiresHumanAction { get; init; }

    /// <summary>Correlates this failure with the request and with the AI Head's own audit record.</summary>
    public required string CorrelationId { get; init; }

    /// <summary>The AI Head's audit record for the failed execution, resolvable under authority.</summary>
    public string? AuditReference { get; init; }

    /// <summary>Convenience constructor from a category, applying the category's retry semantics.</summary>
    public static AiFailure From(AiFailureCategory category, string code, string message, string correlationId) => new()
    {
        Category = category,
        Code = code,
        Message = message,
        CorrelationId = correlationId,
        Retryable = category.IsRetryable(),
        RequiresHumanAction = category == AiFailureCategory.HumanDecisionRequired,
    };
}

/// <summary>
/// The exception type an AI implementation may raise to signal a typed failure across the boundary.
/// </summary>
/// <remarks>
/// <para>
/// Provided so that the AI Head's own layers have a single exception type to throw and one place to
/// translate into an <see cref="AiFailure"/>, rather than each endpoint inventing its own. It carries
/// only the neutral <see cref="AiFailure"/>: no inner exception is accepted, because accepting one
/// would let a provider exception travel inside the boundary-crossing type and be re-surfaced by any
/// caller that unwraps it.
/// </para>
/// <para>
/// An implementation that catches a vendor exception must map it to an <see cref="AiFailureCategory"/>
/// and raise this type. Letting the vendor exception propagate is the defect this type exists to
/// prevent.
/// </para>
/// </remarks>
public sealed class AiCapabilityException : Exception
{
    /// <summary>Creates the exception from a typed failure.</summary>
    public AiCapabilityException(AiFailure failure)
        : base(failure?.Message)
        => Failure = failure ?? throw new ArgumentNullException(nameof(failure));

    /// <summary>Creates the exception from a category, code and caller-safe message.</summary>
    public AiCapabilityException(AiFailureCategory category, string code, string message, string correlationId)
        : this(AiFailure.From(category, code, message, correlationId))
    {
    }

    /// <summary>The typed failure this exception carries.</summary>
    public AiFailure Failure { get; }

    /// <summary>True when a human must act before the capability can be served.</summary>
    public bool RequiresHumanAction => Failure.RequiresHumanAction;
}
