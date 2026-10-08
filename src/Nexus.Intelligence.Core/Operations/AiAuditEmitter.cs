using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// Builds the audit record for a governed execution and writes it to the configured sink.
/// </summary>
/// <remarks>
/// <para>
/// <b>It emits for every outcome, including the ones that never reached a provider.</b> A refused
/// execution has no provider, no usage and no result; it still has a record, and the record still
/// names the capability, the requester, the classification and the status. An audit trail with holes
/// where the refusals were is the trail a reviewer needs least — the refusals are the interesting
/// rows.
/// </para>
/// <para>
/// <b>Every record leaves through <see cref="AiAuditRecord.Sanitized"/>.</b> Both
/// <see cref="Build"/> and <see cref="Emit"/> return the sanitized form, so there is no path that
/// yields an unsanitized record for a caller to persist by a shorter route. The record's own fields
/// are typed and cannot hold a credential; the free text a person writes is what sanitization covers.
/// </para>
/// <para>
/// <b>It does not validate its input and does not throw.</b> An emitter that refused a malformed
/// context would delete the audit trail for exactly the executions that went wrong — the ones whose
/// identity fields are most likely to be malformed — and the loss would be silent, because a missing
/// record looks like an execution that never ran. A malformed record an operator can see beats no
/// record, and the identity fields are already <c>required</c> at the type level.
/// </para>
/// <para>
/// <b>The result digest and every context content hash are withheld for secret content.</b> Hashing a
/// secret into a durable record extends its life rather than ending it, and a digest is only
/// non-reversible against an attacker who does not already hold candidates — the wrong assumption for
/// a value drawn from a small space. The references themselves are kept: a pointer an auditor resolves
/// under authority is a different thing from a digest published beside the record, and withdrawing the
/// pointer would leave the record unable to name the result at all.
/// </para>
/// </remarks>
public sealed class AiAuditEmitter : IAiAuditEmitter
{
    private readonly IAiAuditSink _sink;

    /// <summary>Builds an emitter that writes to a sink.</summary>
    public AiAuditEmitter(IAiAuditSink sink)
    {
        ArgumentNullException.ThrowIfNull(sink);
        _sink = sink;
    }

    /// <inheritdoc />
    public AiAuditRecord Build(AiAuditEmissionContext context)
    {
        ArgumentNullException.ThrowIfNull(context);

        var secret = context.Classification is DataClassification.Secret;

        var record = new AiAuditRecord
        {
            ExecutionId = context.ExecutionId,
            RequestId = context.RequestId,
            CorrelationId = context.CorrelationId,
            Requester = context.Requester,
            Capability = context.Capability,
            Purpose = context.Purpose,
            Classification = context.Classification,
            ContextReferences = WithholdHashes(context.ContextReferences),
            ProviderUsed = context.ProviderUsed,
            ModelUsed = context.ModelUsed,
            PromptVersion = context.PromptVersion,
            ToolsInvoked = [.. context.ToolsInvoked],
            Usage = context.Usage,
            Cost = context.Cost,
            Timing = context.Timing,
            PolicyDecision = context.PolicyDecision,
            Evaluation = context.Evaluation,
            Status = context.Status,
            FailureCategory = context.FailureCategory,

            // Withheld, not failed to compute. A reader cannot tell the two apart from the field alone,
            // which is why the classification travels on the same record.
            //
            // The reference is kept. It is the pointer an auditor resolves under authority, and
            // withdrawing it would leave the record unable to name the result at all — which is a
            // different act from declining to publish a digest of it. This mirrors AiContextReference,
            // which drops the hash of a secret item and keeps the item's identifier.
            ResultHash = secret ? null : context.ResultHash,
            ResultReference = context.ResultReference,
            Timestamp = context.Timestamp,
        };

        return record.Sanitized();
    }

    /// <inheritdoc />
    public AiAuditRecord Emit(AiAuditEmissionContext context)
    {
        var record = Build(context);
        _sink.Write(record);
        return record;
    }

    /// <summary>
    /// Drops the content hash from any context reference whose item is secret.
    /// </summary>
    /// <remarks>
    /// The caller building an <see cref="AiContextReference"/> is already expected to leave the hash
    /// off a secret item. This repeats the rule at the emitter because it is the last point before the
    /// record becomes durable, and because the two places a hash could enter — the context builder and
    /// the emitter's caller — are both outside this class. The check is a null assignment, and the cost
    /// of the redundancy is smaller than the cost of one hash reaching storage because a caller was
    /// written before the rule was.
    /// </remarks>
    private static IReadOnlyList<AiContextReference> WithholdHashes(IReadOnlyList<AiContextReference> references)
    {
        if (references.Count == 0)
        {
            return references;
        }

        var sanitized = new List<AiContextReference>(references.Count);

        foreach (var reference in references)
        {
            sanitized.Add(reference.Classification is DataClassification.Secret
                ? reference with { ContentHash = null }
                : reference);
        }

        return sanitized;
    }
}
