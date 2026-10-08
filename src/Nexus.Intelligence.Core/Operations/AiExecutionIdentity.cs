namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// Mints the identity of one governed execution.
/// </summary>
/// <remarks>
/// <para>
/// <b>W7F TASK 2, and the correction of W7E CF-9.</b> Before this port existed the persisted execution
/// identity <em>was</em> the caller's request identifier: <c>GovernedTurnExecution</c> wrote
/// <c>ExecutionId = request.RequestId</c> into the usage ledger, the execution evidence and the audit
/// emission alike. The two identifiers are not the same thing and the estate cannot treat them as
/// though they were:
/// </para>
/// <list type="bullet">
/// <item><description><b>A request identity belongs to the caller.</b> It is stable across a retry,
/// because stability is the whole point of it: a caller that replays a request is saying "this is the
/// same work", and the request identifier together with the idempotency key is how it says so.</description></item>
/// <item><description><b>An execution identity belongs to the AI Head.</b> It names one actual attempt
/// and must differ between two attempts even when the caller believes it is asking the same question
/// twice — because the estate spent tokens twice, and a record that cannot say so is a record that
/// under-reports spend.</description></item>
/// </list>
/// <para>
/// Collapsing them meant a second execution under a reused request identifier <em>replaced</em> the
/// first execution's audit record and execution evidence, because both stores key on the execution
/// identity. That is CF-9, and it is a defect in evidence rather than in routing: an auditor resolving
/// the reference for the first attempt would be handed the second attempt's record and would have no
/// way to tell.
/// </para>
/// <para>
/// <b>The explicit behaviour this port establishes, stated once so it need not be inferred.</b>
/// </para>
/// <list type="number">
/// <item><description><b>One execution, one identity.</b> Every call to
/// <c>IGovernedTurnExecution.ExecuteAsync</c> mints exactly one identity, on every path out of it,
/// including the refusals that never reach a router.</description></item>
/// <item><description><b>A replay is a new execution.</b> Executing the same request object twice
/// produces two executions, two audit records and two evidence records, and neither overwrites the
/// other. This is the CF-9 correction and it is asserted by test.</description></item>
/// <item><description><b>Idempotency is not defeated by this.</b> Suppressing a duplicate request is
/// <c>TurnPipeline</c>'s job, where the trace store resolves an idempotency key and returns the
/// recorded trace without executing anything. A replay the pipeline suppresses therefore mints no
/// identity at all, because it never reaches this port — the two controls compose rather than
/// compete.</description></item>
/// <item><description><b>A fallback shares its execution's identity.</b> Failover is a second provider
/// call <em>within</em> one execution, not a second execution: the routing decision, the governance
/// decision and the exposure decision that the audit record carries are per-request facts and would be
/// ambiguous to attribute across several execution identities. The individual calls are distinguished
/// by their attempt identity instead, which is what makes a fallback separately attributable without
/// splitting the record that explains it.</description></item>
/// </list>
/// <para>
/// <b>The port exists so the identity is injectable rather than ambient.</b> A test asserting "two
/// executions produce two distinct identities" cannot do so against a <c>Guid.NewGuid()</c> called
/// inline: it would be proving that two GUIDs differ, which is a fact about GUIDs. Injecting a
/// deterministic source lets the same test name the identities the estate actually wrote, and lets a
/// replay test prove that one request identifier produced two of them rather than merely that the two
/// values were unequal.
/// </para>
/// <para>
/// <b>It is not a source of randomness for anything else.</b> No control depends on the identity being
/// unguessable — the audit and evidence stores are reached through authorized read ports, never by
/// presenting an identity — so a replacement source that produced predictable values would weaken
/// nothing. It is stated here so that a later reader does not promote the GUID into an authorization
/// token it was never meant to be.
/// </para>
/// </remarks>
public interface IAiExecutionIdSource
{
    /// <summary>Returns an identity no previous call on this source has returned.</summary>
    string Next();
}

/// <summary>
/// The shipped execution-identity source: a lowercase hexadecimal GUID.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why a GUID, and not a counter or a string derived from the request.</b> A counter is unique only
/// within one process and one run, so two AI Head instances — or one instance after a restart — would
/// mint colliding identities, and a collision silently overwrites audit evidence, which is precisely
/// the failure this port exists to remove. A value derived from the request identifier plus an attempt
/// number would be unique, but it would also re-encode the caller's identifier into the execution
/// identity and so preserve the coupling TASK 2 asks to break.
/// </para>
/// <para>
/// <b>Format.</b> The <c>"N"</c> specifier: thirty-two lowercase hexadecimal characters with no
/// separators. That is the same shape <c>TurnPipeline</c> already mints its turn identifiers in, so an
/// operator reading a turn identifier and an execution identity side by side is not asked to tell two
/// conventions apart, and neither can be mistaken for the other's kind.
/// </para>
/// </remarks>
public sealed class GuidAiExecutionIdSource : IAiExecutionIdSource
{
    /// <inheritdoc />
    public string Next() => Guid.NewGuid().ToString("N");
}
