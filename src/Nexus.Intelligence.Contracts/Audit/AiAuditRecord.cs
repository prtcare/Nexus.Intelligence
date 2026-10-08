using System.Text.Json;
using System.Text.Json.Serialization;

namespace Nexus.Intelligence.Contracts;

/// <summary>
/// A reference to context that was supplied to an execution, without the context itself.
/// </summary>
/// <remarks>
/// <para>
/// The audit record answers "what was this execution given?" by naming <em>what</em> was given and
/// <em>how sensitive it was</em>, not by retaining a copy. This is the structural half of the rule
/// that raw sensitive context must not be stored unnecessarily: there is no field on
/// <see cref="AiAuditRecord"/> capable of holding a context body.
/// </para>
/// <para>
/// <see cref="ContentHash"/> is a digest of the content as supplied, so that an auditor holding the
/// original can prove it was the content used, and an auditor without it learns nothing. A hash is
/// not a redaction of a low-entropy secret — which is why the classification is carried alongside and
/// why <see cref="DataClassification.Secret"/> context is recorded as a reference with no hash at all.
/// </para>
/// </remarks>
public sealed record AiContextReference
{
    /// <summary>The <see cref="ContextItem.Id"/> the caller supplied.</summary>
    public required string ContextItemId { get; init; }

    /// <summary>The classification of this item.</summary>
    public required DataClassification Classification { get; init; }

    /// <summary>
    /// A digest of the content as supplied. <see langword="null"/> when the item is
    /// <see cref="DataClassification.Secret"/>, because hashing a secret into a durable record extends
    /// its life rather than ending it.
    /// </summary>
    public string? ContentHash { get; init; }

    /// <summary>True when <see cref="ContentHash"/> is absent because hashing was refused, not because it failed.</summary>
    public bool HashWithheld => ContentHash is null;
}

/// <summary>
/// The one operational audit record for AI execution.
/// </summary>
/// <remarks>
/// <para>
/// One record type, written for every execution regardless of outcome — a blocked execution and a
/// successful one produce the same shape, because an audit trail with holes where the refusals were is
/// exactly the trail a reviewer needs least.
/// </para>
/// <para>
/// <b>What is deliberately absent:</b> credentials, endpoints, provider error bodies, raw context
/// bodies, prompt text, and model output. The prompt is referenced by <see cref="PromptVersion"/> and
/// the output by <see cref="ResultReference"/> and <see cref="ResultHash"/>; both are resolvable under
/// authority from the store that owns them. The record is a ledger, not a copy of the payload.
/// </para>
/// <para>
/// <b>Provider and model are recorded here and nowhere else.</b> This is the record an auditor
/// resolves an <see cref="AiExecutionReference"/> against. Keeping them off
/// <see cref="AiCapabilityResponse"/> and on this record is the whole arrangement.
/// </para>
/// </remarks>
public sealed record AiAuditRecord
{
    /// <summary>The AI Head's identifier for this execution.</summary>
    public required string ExecutionId { get; init; }

    /// <summary>The caller's request identifier.</summary>
    public required string RequestId { get; init; }

    /// <summary>Correlates across services.</summary>
    public required string CorrelationId { get; init; }

    /// <summary>Who asked.</summary>
    public required AiRequesterIdentity Requester { get; init; }

    /// <summary>What was asked for.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>Why the caller said it was asking.</summary>
    public required string Purpose { get; init; }

    /// <summary>The classification of the request as submitted.</summary>
    public required DataClassification Classification { get; init; }

    /// <summary>References to the context supplied. Never the context itself.</summary>
    public IReadOnlyList<AiContextReference> ContextReferences { get; init; } = [];

    /// <summary>Which provider served it. Evidence of what happened.</summary>
    public string? ProviderUsed { get; init; }

    /// <summary>Which model served it. Evidence of what happened.</summary>
    public string? ModelUsed { get; init; }

    /// <summary>The prompt or instruction set version applied.</summary>
    public string? PromptVersion { get; init; }

    /// <summary>Tools the execution invoked, by identifier.</summary>
    public IReadOnlyList<string> ToolsInvoked { get; init; } = [];

    /// <summary>Tokens and units consumed.</summary>
    public AiTokenUsage Usage { get; init; } = AiTokenUsage.None;

    /// <summary>What it cost.</summary>
    public AiCost? Cost { get; init; }

    /// <summary>How long it took.</summary>
    public AiTiming? Timing { get; init; }

    /// <summary>What policy decided.</summary>
    public AiPolicyDecision? PolicyDecision { get; init; }

    /// <summary>What evaluation concluded.</summary>
    public AiEvaluationResult Evaluation { get; init; } = AiEvaluationResult.NotEvaluated;

    /// <summary>The terminal status.</summary>
    public required AiExecutionStatus Status { get; init; }

    /// <summary>The failure category, when the execution did not succeed.</summary>
    public AiFailureCategory? FailureCategory { get; init; }

    /// <summary>A digest of the result, so a later-disputed output can be tied to the record.</summary>
    public string? ResultHash { get; init; }

    /// <summary>A resolvable reference to the stored result, under authority.</summary>
    public string? ResultReference { get; init; }

    /// <summary>When the execution completed.</summary>
    public required DateTimeOffset Timestamp { get; init; }

    /// <summary>
    /// Returns a copy with every free-text field routed through <see cref="AiRedaction"/>.
    /// </summary>
    /// <remarks>
    /// The record's <em>own</em> fields are typed and cannot hold a credential, so this covers the
    /// fields a human or caller writes: <see cref="Purpose"/> and the principal, tenant, product and
    /// workspace identifiers. Identifiers are included because opaque does not mean harmless — an
    /// operator pasting a connection string into a tenant field is a plausible accident, and the cost
    /// of covering it is a string scan.
    /// </remarks>
    public AiAuditRecord Sanitized() => this with
    {
        Purpose = AiRedaction.Redact(Purpose) ?? string.Empty,
        Requester = Requester with
        {
            PrincipalId = AiRedaction.Redact(Requester.PrincipalId) ?? string.Empty,
            TenantId = AiRedaction.Redact(Requester.TenantId),
            ProductId = AiRedaction.Redact(Requester.ProductId),
            WorkspaceId = AiRedaction.Redact(Requester.WorkspaceId),
        },
        ContextReferences = ContextReferences
            .Select(r => r with { ContextItemId = AiRedaction.Redact(r.ContextItemId) ?? string.Empty })
            .ToArray(),
    };
}

/// <summary>
/// The serializer path for audit and control records, with redaction applied on the way out.
/// </summary>
/// <remarks>
/// <para>
/// A record must not be persisted by calling <see cref="JsonSerializer"/> directly: the normal
/// serializer path is the one a caller reaches for, and if the safe path is a different, longer path
/// then the unsafe one is what will be used. <see cref="Serialize"/> is therefore the recommended
/// entry point and it sanitizes before it writes, so the default is the safe one.
/// </para>
/// <para>
/// <b>What this can and cannot enforce.</b> It enforces that anything flowing through it has been
/// redacted. It cannot enforce that a future caller uses it — that is what a code review and, at the
/// far end, a boundary test on the persistence layer are for. The directive's "where enforceable" is
/// read as: enforceable on the path, not enforceable against a caller who deliberately bypasses it.
/// </para>
/// </remarks>
public static class AiAuditSerialization
{
    /// <summary>Options used for audit and control records.</summary>
    public static JsonSerializerOptions Options { get; } = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = false,
    };

    /// <summary>Sanitizes and serialises an audit record.</summary>
    public static string Serialize(AiAuditRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        return JsonSerializer.Serialize(record.Sanitized(), Options);
    }
}
