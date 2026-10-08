using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Turns;
using Nexus.Platform.Contracts.Core;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Gateway;

/// <summary>
/// The AI Head's implementation of the capability boundary: it translates a semantic request onto the
/// one governed execution path and projects what comes back onto the caller-facing response.
/// </summary>
/// <remarks>
/// <para>
/// <b>It translates and projects. It does not execute, and it cannot.</b> Every invocation reaches a
/// provider through <see cref="IGovernedTurnExecution"/> or not at all, and no collaborator held here
/// can reach a provider directly — there is no model step, no model gateway, no credential and no
/// endpoint among them. That is the same structural guarantee <c>TurnPipeline</c> makes, made again
/// for a second entry point, because a second entry point is exactly where the first one's discipline
/// gets bypassed.
/// </para>
/// <para>
/// <b>Why it implements the caller's interface rather than a parallel server port.</b> TASK 9 forbids
/// creating a competing second AI client, and a server-side interface with the same two methods would
/// be one: two shapes to keep in step, drifting the first time only one of them changed. The
/// capability boundary is one contract with two roles — a Head serves it, a consumer transports it —
/// and the type below is the serving role. It is not "transport" in
/// <see cref="IAiCapabilityClient"/>'s sense, and that type's remarks now say so.
/// </para>
/// <para>
/// <b>Provider and model are never copied onto the response, and that is a projection decision rather
/// than a filter.</b> The operations read model this type consults does carry both, because it is an
/// operator surface built from the audit record. Nothing below copies them: the caller receives
/// <see cref="AiExecutionReference"/>, which is the identity of the execution and nothing about who
/// performed it. A test asserts the projection rather than the intention, because a filter is a line
/// somebody can delete.
/// </para>
/// <para>
/// <b>A non-success status never travels without a typed failure.</b> TASK 11 requires internal and
/// vendor failures to arrive as an <see cref="AiFailureCategory"/>, and the corollary is that a
/// caller can branch on the category without first asking whether there is one to branch on. Where
/// the governed path reports a failure it is passed through unchanged; where it reports none, one is
/// derived from the governance decision that produced the refusal.
/// </para>
/// <para>
/// <b>No exception from below this line crosses it.</b> A vendor exception that reached a caller
/// would carry a provider's own error body — a model name, an endpoint, a request id — which is what
/// the boundary exists to contain. <see cref="AiCapabilityException"/> is unwrapped to its typed
/// failure; anything else becomes a neutral <see cref="AiFailureCategory.AiUnavailable"/> whose
/// message is written here and contains nothing from the exception. The raw cause is not reproduced
/// on the response, deliberately: it is the AI Head's own operational record, not a caller's.
/// </para>
/// <para>
/// <b>Caller cancellation is not an AI failure.</b> An <see cref="OperationCanceledException"/> is
/// rethrown, because a caller that cancelled its own request must not be told the estate failed.
/// Caller defects — a malformed request — throw for the same reason
/// <see cref="IAiCapabilityClient"/> gives: they are not AI failures and have no business being
/// reported as one.
/// </para>
/// </remarks>
public sealed class AiCapabilityGateway : IAiCapabilityClient
{
    private readonly IGovernedTurnExecution _execution;
    private readonly IAiGatewayAvailabilitySource _availability;
    private readonly AiCapabilityRegister _capabilities;
    private readonly IAiOperationsReadModel _operations;
    private readonly IToolCatalog _toolCatalog;
    private readonly IAiExecutionIdSource _invocationIds;
    private readonly TimeProvider _time;

    /// <summary>Composes the gateway over the governed path and the operations read surface.</summary>
    public AiCapabilityGateway(
        IGovernedTurnExecution execution,
        IAiGatewayAvailabilitySource availability,
        AiCapabilityRegister capabilities,
        IAiOperationsReadModel operations,
        IToolCatalog toolCatalog,
        IAiExecutionIdSource invocationIds,
        TimeProvider time)
    {
        ArgumentNullException.ThrowIfNull(execution);
        ArgumentNullException.ThrowIfNull(availability);
        ArgumentNullException.ThrowIfNull(capabilities);
        ArgumentNullException.ThrowIfNull(operations);
        ArgumentNullException.ThrowIfNull(toolCatalog);
        ArgumentNullException.ThrowIfNull(invocationIds);
        ArgumentNullException.ThrowIfNull(time);

        _execution = execution;
        _availability = availability;
        _capabilities = capabilities;
        _operations = operations;
        _toolCatalog = toolCatalog;
        _invocationIds = invocationIds;
        _time = time;
    }

    /// <inheritdoc />
    public async Task<AiCapabilityResponse> InvokeAsync(
        AiCapabilityRequest request,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        Validate(request);

        var started = _time.GetTimestamp();

        // The availability question is asked before anything is translated, because the answer
        // changes what the caller is told rather than what the estate does: a Head that cannot serve
        // must say so without spending an execution on discovering it.
        var availability = _availability.Read();

        if (!availability.IsServable)
        {
            return Degraded(request, availability, started);
        }

        try
        {
            var outcome = await _execution
                .ExecuteAsync(await TranslateAsync(request, ct).ConfigureAwait(false), ct)
                .ConfigureAwait(false);

            return Project(request, outcome, started);
        }
        catch (AiCapabilityException caught)
        {
            // Already a typed failure, mapped by whichever layer saw the vendor exception first. It is
            // re-projected rather than re-thrown so that the caller receives a response like every
            // other failure, and so the shape of the answer does not depend on which layer failed.
            return Failed(request, caught.Failure, started);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            // Nothing from the exception is reproduced. See the type's remarks: the message below is
            // written here, and the raw cause belongs to the AI Head's own operational record.
            return Failed(
                request,
                AiFailure.From(
                    AiFailureCategory.AiUnavailable,
                    "gateway_execution_faulted",
                    "The AI Head could not complete this execution. Nothing about what the caller sent "
                    + "was refused; the failure was internal to serving it.",
                    CorrelationOf(request)),
                started);
        }
    }

    /// <inheritdoc />
    public Task<IReadOnlyList<AiCapabilityRegistration>> ListCapabilitiesAsync(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();

        // The register's own entries, unprojected. They carry the governance facts a consumer needs -
        // what the capability is for, how it degrades, who owns it - and no model, vendor, endpoint or
        // tool identifier, because the type has no member for one. Rebuilding the list here into a
        // narrower shape would create a second answer to "what will this Head serve" that could
        // disagree with the first.
        return Task.FromResult(_capabilities.List());
    }

    /// <summary>Translates a semantic request onto the governed path's own request record.</summary>
    /// <remarks>
    /// <para>
    /// <b>The capability request is already the richer envelope, so little is derived.</b>
    /// <see cref="AiCapabilityRequest"/> carries the purpose, the classification, the requester and the
    /// execution policy that a conversational turn has to have derived for it from a Product's wire
    /// contract. A caller of this gateway has already stated all four, and the translation is therefore
    /// a rename rather than an inference — which is the property that keeps this layer free of policy.
    /// </para>
    /// <para>
    /// <b>Two members are supplied rather than carried across, and each has a reason.</b>
    /// </para>
    /// <list type="bullet">
    /// <item><description>
    /// <b>The invocation identity.</b> <see cref="InvocationIdentity"/> is the Platform meter's key and
    /// is minted fresh per invocation rather than taken from the caller's request identifier. Reusing
    /// the request identifier there would reproduce, in the metering store, exactly the defect W7F
    /// corrected in the audit store: two executions a caller considers "the same request" would share
    /// one metering key and the second would be indistinguishable from the first. The identity is
    /// minted from the same port the governed path mints execution identities from, so the estate has
    /// one source of AI-Head-minted identifiers rather than two.
    /// </description></item>
    /// <item><description>
    /// <b>The constraints.</b> <see cref="TurnConstraints"/> is the tool loop's posture and the
    /// execution policy is the caller's statement of what it requires. They are the same facts in two
    /// vocabularies — the governed path's and the capability contract's — and the mapping is total:
    /// every field of the former that has a source in the latter is filled from it, and
    /// <c>RequireApprovalForWrites</c> has no source and is left at its default of <c>true</c>.
    /// </description></item>
    /// </list>
    /// <para>
    /// <b>What is deliberately not mapped: the caller's tool permission ceiling.</b>
    /// <see cref="AiCapabilityRequest.Tools"/> is carried across as an <em>offer</em> — which tools the
    /// caller is willing to see used — and not as an authority.
    /// <c>GovernedTurnExecution</c> derives the effective profile from the AI tool registry's own
    /// classification of whatever was offered, taking the widest effect among them, and treating an
    /// unknown tool as <see cref="ToolSideEffectClass.Destructive"/>. The consequence is that a caller
    /// which understates its ceiling does not thereby lower the one that applies: it is either refused
    /// by the tool approval gate or served at the registry's classification, never served at the
    /// lower number it typed. Honouring the declared number would make a caller-supplied field the
    /// authority for a security ceiling, which is the direction that can only ever widen.
    /// </para>
    /// <para>
    /// <b>The same reading applies to <c>RequireApprovalForWrites</c>, and more sharply.</b> A caller
    /// cannot turn the write-approval gate off by setting it false here, because the profile the
    /// governed path derives does not read it. That is stated rather than implied: the field is
    /// accepted — it is part of the published contract — and it is not an authority.
    /// </para>
    /// </remarks>
    private async Task<GovernedTurnRequest> TranslateAsync(AiCapabilityRequest request, CancellationToken ct)
    {
        var offered = await OfferedToolsAsync(request, ct).ConfigureAwait(false);

        return new GovernedTurnRequest
        {
            RequestId = request.RequestId,
            Purpose = request.Purpose,
            Capability = request.Capability,
            Requester = request.Requester,
            Input = request.Input,
            Context = request.Context,
            Classification = request.Classification,
            Execution = request.Execution,

            // The tools the catalogue resolved for this caller's offer, and the identifiers the router
            // answers its own question with. The two are stated separately because they are read
            // separately: the descriptors reach the model step and the tool loop, the identifiers reach
            // the routing context's per-candidate tool-permission gate.
            OfferedToolIds = [.. offered.Select(tool => tool.ToolId)],
            OfferedTools = offered,

            // A capability invocation names no agent and no instruction set, and neither is invented
            // for it. An agent's registration is a grant of specific work with its own capability list
            // and its own side-effect ceiling; a capability request is the caller stating the work
            // directly, so attaching an agent would apply two authorities to one decision. An
            // instruction set has the same shape of problem: naming a prompt here would be this layer
            // choosing how the Head's models are addressed.
            AgentId = null,
            PromptId = null,

            Identity = new InvocationIdentity(
                request.Requester.TenantId ?? string.Empty,
                request.Requester.ProductId ?? string.Empty,
                _invocationIds.Next(),
                request.Requester.PrincipalId),
            Constraints = new TurnConstraints
            {
                MaxCost = request.Execution.MaxCost,
                LatencyBudget = request.Execution.LatencyBudget,
                AllowedTools = [.. offered.Select(tool => tool.ToolId)],

                // No source on the request, and left at the default rather than defaulted from the
                // request's own posture. The governed path does not read the caller's value for this,
                // so stating one here would be a parameter that looks like a control.
                RequireApprovalForWrites = true,
                ModelHint = null,
            },
            CorrelationId = request.CorrelationId ?? request.RequestId,
            IdempotencyKey = request.IdempotencyKey,
        };
    }

    /// <summary>The catalogue's descriptors for the tools the caller offered.</summary>
    /// <remarks>
    /// <para>
    /// A tool the platform catalogue does not list is dropped rather than offered, and the drop is
    /// silent here because governance reports it: an identifier that survives to the router but is
    /// absent from the AI tool registry is refused as <c>governance.tool.unknown</c>, which is a
    /// recorded decision with a code. An identifier the <em>catalogue</em> does not know never reaches
    /// the registry to be refused, so the caller learns nothing about it — which is correct, because
    /// this gateway will not confirm the existence of a tool the estate does not have.
    /// </para>
    /// <para>
    /// The intersection can only narrow. It is the platform layer's own catalogue, resolving the
    /// caller's own list, so the result is a subset of what was asked for and nothing is added.
    /// </para>
    /// </remarks>
    private async Task<IReadOnlyList<ToolDescriptor>> OfferedToolsAsync(
        AiCapabilityRequest request,
        CancellationToken ct)
    {
        if (request.Tools.AllowedToolIds.Count == 0)
        {
            return [];
        }

        var offered = request.Tools.AllowedToolIds.ToHashSet(StringComparer.Ordinal);
        var catalogue = await _toolCatalog.ListAsync(ct).ConfigureAwait(false);

        return [.. catalogue.Where(tool => offered.Contains(tool.ToolId))];
    }

    /// <summary>Projects a governed outcome onto the caller-facing response.</summary>
    /// <remarks>
    /// <para>
    /// <b>Status, failure, output, citations and fallback come from the outcome; usage and cost come
    /// from the operations read model.</b> The split is deliberate rather than convenient. The outcome
    /// is the authority for what happened to this request — it is the value the governed path returned,
    /// in the same call, and re-reading it from a store would make the response a second-hand account
    /// of its own result. Usage and cost are the two facts the outcome does not carry, and for those
    /// the ledger is the authority: it counts every provider call the execution made, including the
    /// ones a fallback made, where the outcome carries only the call that survived.
    /// </para>
    /// <para>
    /// <b>An unpublished ledger entry is reported as unpriced, never as free.</b> TASK 5: cost is null
    /// when no record exists, and null when a record exists but carries
    /// <see cref="AiCostBasis.Unpriced"/>. Zero would be a claim that the execution cost nothing, and
    /// the estate does not know that — it knows it has no price for it.
    /// </para>
    /// </remarks>
    private AiCapabilityResponse Project(
        AiCapabilityRequest request,
        GovernedTurnOutcome outcome,
        long started)
    {
        var recorded = _operations.Execution(outcome.ExecutionId);
        var status = StatusOf(outcome);
        var failure = outcome.Failure ?? FailureFor(outcome, status, CorrelationOf(request));

        return new AiCapabilityResponse
        {
            RequestId = request.RequestId,
            Capability = request.Capability,
            CorrelationId = CorrelationOf(request),
            Status = status,

            // The model's own text. Absent when no provider was called, which is the honest reading of
            // "no output" rather than an empty string claiming the model said nothing.
            Output = outcome.Result?.Result.Message?.Content,

            // No structured-output mode is implemented on the governed path, so nothing is claimed
            // here. Null is "not asked for and not produced"; an empty document would be a different
            // and false statement. Recorded as W7F carry-forward rather than left to be discovered.
            StructuredOutput = null,

            Citations = CitationsFor(outcome),

            // The ledger's totals, which count every provider call the execution made. Read from the
            // record rather than summed from the outcome, because the outcome's usage is the surviving
            // call's and a fallback's spend would vanish from the caller's figure.
            Usage = recorded is null
                ? AiTokenUsage.None
                : new AiTokenUsage { InputTokens = recorded.TokensIn, OutputTokens = recorded.TokensOut },

            Cost = CostOf(recorded),

            // The caller's own wait, measured here. The AI Head's internal breakdown is not on the
            // caller-facing contract and must not be: a caller that could separate provider time from
            // pre-execution time would be reading the Head's internal structure.
            Elapsed = _time.GetElapsedTime(started),

            PolicyDecision = new AiPolicyDecision
            {
                Allowed = outcome.Decision.IsAllowed,
                RulesApplied = outcome.Decision.RulesApplied,
                Reason = outcome.Decision.IsAllowed ? null : outcome.Decision.Reason,
            },
            Evaluation = AiEvaluationResult.NotEvaluated,
            Failure = failure,

            // Present unless nothing ran. A degraded response carries none, and the absence is the
            // label: see AiCapabilityResponse.Execution.
            Execution = new AiExecutionReference { ExecutionId = outcome.ExecutionId },
            AuditReference = outcome.AuditReference,

            // From the failover record, which is present on every execution the operational plane saw.
            // A null here means the plane did not run, which is a different fact from "no failover was
            // needed" - and neither is reported to the caller as the other.
            UsedFallback = outcome.Failover?.UsedFallback ?? false,
        };
    }

    /// <summary>The response for a Head that cannot serve, with nothing executed.</summary>
    /// <remarks>
    /// <para>
    /// <b>Nothing ran, so no execution reference is issued.</b> An execution identity for work that
    /// never happened would resolve, under authority, to an audit record that does not exist — and a
    /// caller holding it would reasonably conclude the work was attempted.
    /// </para>
    /// <para>
    /// <b>Whether this reads as a failure or as a degraded answer is the caller's decision, and it is
    /// taken from the caller's own policy.</b> <see cref="AiDegradationPreference.Fail"/> means there is
    /// no deterministic path and the operation cannot complete; the other two preferences mean the
    /// caller has one. Reporting a refusal to a caller that asked to be told, or a degraded label to a
    /// caller that asked to fail, would both be the estate deciding something the caller already said.
    /// </para>
    /// <para>
    /// <b>The reason is provider-neutral.</b> <see cref="AiGatewayAvailability.Reason"/> names no
    /// route, no provider and no model — the availability projection that computed it read all three
    /// and published none. That is the whole of TASK 7's second clause.
    /// </para>
    /// </remarks>
    private AiCapabilityResponse Degraded(
        AiCapabilityRequest request,
        AiGatewayAvailability availability,
        long started)
    {
        var failure = AiFailure.From(
            AiFailureCategory.AiUnavailable,
            "ai_head_unavailable",
            $"The AI Head is not serving requests ({availability.State}). "
            + "The request was not attempted, so nothing about it was refused.",
            CorrelationOf(request));

        var status = request.Execution.OnDegradation is AiDegradationPreference.Fail
            ? AiExecutionStatus.Failed
            : AiExecutionStatus.Degraded;

        return new AiCapabilityResponse
        {
            RequestId = request.RequestId,
            Capability = request.Capability,
            CorrelationId = CorrelationOf(request),
            Status = status,
            PolicyDecision = AiPolicyDecision.AllowedByDefault,

            // The label the degradation rules require, and it is true only in the degraded reading: a
            // caller that asked to fail has not taken a deterministic path, it has been refused.
            IsDegraded = status is AiExecutionStatus.Degraded,
            Failure = failure,
            Elapsed = _time.GetElapsedTime(started),
        };
    }

    /// <summary>The response for a failure raised below this line, with no outcome to project.</summary>
    private AiCapabilityResponse Failed(AiCapabilityRequest request, AiFailure failure, long started) => new()
    {
        RequestId = request.RequestId,
        Capability = request.Capability,
        CorrelationId = CorrelationOf(request),
        Status = AiExecutionStatus.Failed,
        Failure = failure,
        Elapsed = _time.GetElapsedTime(started),
    };

    /// <summary>How an execution ended, from the governance decision and the invocation record.</summary>
    /// <remarks>
    /// <b>The governance verdict is read before the invocation record, and the order matters.</b> A
    /// refusal is a refusal whether or not something was later attempted under it — a fallback that
    /// failed does not turn a permitted execution into a blocked one, and a permitted execution whose
    /// only route failed is a failure rather than a block. Reading the verdict first keeps those two
    /// apart, which is the distinction a caller branches on.
    /// </remarks>
    private static AiExecutionStatus StatusOf(GovernedTurnOutcome outcome) => outcome.Decision.Verdict switch
    {
        AiGovernanceVerdict.Block => AiExecutionStatus.Blocked,
        AiGovernanceVerdict.HumanDecisionRequired => AiExecutionStatus.PendingHumanDecision,
        _ when outcome.Invoked && outcome.Result?.Result.Success is true => AiExecutionStatus.Succeeded,
        _ => AiExecutionStatus.Failed,
    };

    /// <summary>
    /// The typed failure for an execution the governed path reported as failing without naming a cause.
    /// </summary>
    /// <remarks>
    /// The governed path raises a failure with every refusal it produces, so this is a backstop rather
    /// than a path — but it is the backstop that makes "a non-success response always carries a
    /// category" true rather than usually true. It states the governance rule that decided, so a caller
    /// asking why gets the rule identifier even here, and it claims
    /// <see cref="AiFailureCategory.AiUnavailable"/> rather than inventing a more specific cause the
    /// estate did not observe.
    /// </remarks>
    private static AiFailure? FailureFor(
        GovernedTurnOutcome outcome,
        AiExecutionStatus status,
        string correlationId)
    {
        if (status is AiExecutionStatus.Succeeded)
        {
            return null;
        }

        return AiFailure.From(
            AiFailureCategory.AiUnavailable,
            "execution_failed_without_a_reported_cause",
            $"The execution ended as '{status}' and no typed cause was recorded against it. The "
            + $"governing rule was '{outcome.Decision.RuleId}': {outcome.Decision.Reason}",
            correlationId);
    }

    /// <summary>The citations in the answer, resolved against the context that was actually admitted.</summary>
    private static IReadOnlyList<Citation> CitationsFor(GovernedTurnOutcome outcome) =>
        CitationExtractor.Extract(
            outcome.Result?.Result.Message?.Content,
            outcome.Context.Select(item => item.Item.Id).ToHashSet(StringComparer.Ordinal));

    /// <summary>The caller's cost, or null where the estate has no price for the execution.</summary>
    /// <remarks>
    /// The read model already states that an unpriced execution has no amount — it reports the amount
    /// as null and the basis as <see cref="AiCostBasis.Unpriced"/> in the same view. This type does not
    /// convert that to zero and does not substitute the estimate for the measurement: a caller that
    /// receives the estimate as though it were the spend has been told a number the estate never
    /// observed.
    /// </remarks>
    private static AiCost? CostOf(AiExecutionOperationsView? recorded) =>
        recorded?.Cost is { } amount
            ? new AiCost
            {
                Amount = amount,
                Currency = recorded.Currency ?? string.Empty,
                IsEstimated = recorded.CostBasis is AiCostBasis.Estimated,
            }
            : null;

    private static string CorrelationOf(AiCapabilityRequest request)
        => request.CorrelationId ?? request.RequestId;

    /// <summary>Rejects a request that is malformed rather than reporting it as an AI failure.</summary>
    /// <remarks>
    /// These throw, for the reason <see cref="IAiCapabilityClient"/> gives: a caller defect is not an
    /// AI failure and a caller that receives it as one will eventually stop distinguishing the two.
    /// The checks are the fields the audit record is keyed by — without them an execution would be
    /// recorded against an identity the estate cannot resolve, which is worse than refusing it.
    /// </remarks>
    private static void Validate(AiCapabilityRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.RequestId))
        {
            throw new ArgumentException(
                "A capability request must state a RequestId: it is the audit join key, so an execution "
                + "recorded without one could not be correlated back to the caller that asked for it.",
                nameof(request));
        }

        if (string.IsNullOrWhiteSpace(request.IdempotencyKey))
        {
            throw new ArgumentException(
                "A capability request must state an IdempotencyKey. It is what makes a transport retry "
                + "distinguishable from a new request, and a request that states neither cannot be "
                + "replayed safely.",
                nameof(request));
        }

        if (string.IsNullOrWhiteSpace(request.Purpose))
        {
            throw new ArgumentException(
                "A capability request must state its Purpose. It is stored as audit metadata and is the "
                + "only record of why the caller wanted the work; it cannot be derived after the fact.",
                nameof(request));
        }

        if (string.IsNullOrWhiteSpace(request.Requester?.PrincipalId))
        {
            throw new ArgumentException(
                "A capability request must name the principal the work is done for. An execution that "
                + "cannot be attributed cannot be audited, which is the audit record's first purpose.",
                nameof(request));
        }
    }
}
