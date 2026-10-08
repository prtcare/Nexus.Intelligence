namespace Nexus.Intelligence.Contracts;

public sealed record IntelligenceTurnRequest
{
    public required string TenantId { get; init; }
    public required string ProductId { get; init; }
    public required ScopeRef Scope { get; init; }
    public required ActorRef Actor { get; init; }
    public required TurnInput Input { get; init; }
    public ContextBundle Context { get; init; } = ContextBundle.Empty;
    public TurnConstraints Constraints { get; init; } = TurnConstraints.Default;
    public required string IdempotencyKey { get; init; }
    public string? CorrelationId { get; init; }

    /// <summary>
    /// How sensitive this turn is, as the caller declares it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Nullable, unlike the same field on <see cref="AiCapabilityRequest"/>, and the difference is
    /// deliberate rather than an oversight.</b> On the capability contract the field is required with no
    /// default, because that type is the AI Head's own contract and can make a missing classification a
    /// compile error. This type is a Product's wire contract: making it required would fail every Product
    /// that has not yet been taught to send one, and a deserialisation failure is a worse outcome than a
    /// recorded default — the Product's feature breaks entirely rather than being classified
    /// conservatively.
    /// </para>
    /// <para>
    /// <b>The pipeline supplies the default and records that it did</b>, so a defaulted turn is
    /// distinguishable in the trace from one the caller classified as
    /// <see cref="DataClassification.Internal"/>. Absence means "the caller did not say", which is
    /// information an auditor wants; collapsing it into a declared Internal would destroy it.
    /// </para>
    /// <para>
    /// A Product that sends nothing therefore gets the conservative reading and a visible trace, and a
    /// Product that sends a value gets exactly what it declared. Neither can lower the classification the
    /// exposure policy gates on by saying nothing.
    /// </para>
    /// </remarks>
    public DataClassification? Classification { get; init; }
}
