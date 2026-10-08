using System.Security.Cryptography;
using System.Text;
using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Governance;
using Nexus.Intelligence.Core.Models;
using Nexus.Intelligence.Core.Operations;
using Nexus.Platform.Contracts.Core;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

/// <summary>
/// Everything the governed path needs to know about one turn, and nothing about how it will be served.
/// </summary>
/// <remarks>
/// <para>
/// <b>There is no model and no provider here.</b> Not by omission — by construction, and for the reason
/// <see cref="AiCapabilityRequest"/> gives: a caller names the work, and the AI Head decides who does it.
/// The turn pipeline builds this type and has no field in which to name a route, so the pipeline cannot
/// pre-empt the router by accident or by edit. That is a stronger guarantee than a rule saying it must
/// not, and it is the one the directive's "must not choose provider directly" actually needs.
/// </para>
/// <para>
/// <b>It carries the facts the turn envelope cannot supply.</b> <see cref="IntelligenceTurnRequest"/> has
/// no classification, no requester identity and no execution policy, because it predates the exposure
/// model and is a Product's wire contract. This type is where the pipeline states what it derived for
/// each of them, so the derivation is one visible act in one place rather than a scattering of defaults
/// across a five-hundred-line method.
/// </para>
/// </remarks>
public sealed record GovernedTurnRequest
{
    /// <summary>The caller's request identifier. The audit join key.</summary>
    public required string RequestId { get; init; }

    /// <summary>Why the caller is asking, in the caller's own words.</summary>
    public required string Purpose { get; init; }

    /// <summary>
    /// What the caller is asking for, in the capability vocabulary.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>A capability is not a route, which is why it belongs here and a model does not.</b> Stating
    /// <c>chat.complete</c> says what work is needed; it says nothing about which model or provider
    /// performs it, and the router remains the only thing that decides that. The distinction is precisely
    /// the one that lets this record carry the field while still having no field in which to name a route.
    /// </para>
    /// <para>
    /// <b>Required rather than defaulted, and the execution does not supply it.</b> Until W7D the
    /// capability was hardcoded inside the execution, so every entry point silently asked for the same
    /// one and a second entry point could not ask for anything else. That hardcoding is what made the plan
    /// endpoint's request indistinguishable from a conversational turn's in the audit record, when they
    /// are different work with different quality expectations.
    /// </para>
    /// </remarks>
    public required CapabilityId Capability { get; init; }

    /// <summary>Who is asking, and within what scope.</summary>
    public required AiRequesterIdentity Requester { get; init; }

    /// <summary>The caller's input.</summary>
    public required TurnInput Input { get; init; }

    /// <summary>The context the caller supplied, unfiltered. The exposure path narrows it.</summary>
    public required ContextBundle Context { get; init; }

    /// <summary>
    /// How sensitive the turn is. Required with no default, for the reason the capability contract gives:
    /// a default would make "deliberately internal" indistinguishable from "nobody thought about it".
    /// The pipeline supplies the caller's declaration or a stated substitute, and records which it did.
    /// </summary>
    public required DataClassification Classification { get; init; }

    /// <summary>What the caller requires of the execution: time, cost, quality, degradation.</summary>
    public required AiExecutionPolicy Execution { get; init; }

    /// <summary>The tools the pipeline is willing to offer the execution, before governance narrows them.</summary>
    public required IReadOnlyList<string> OfferedToolIds { get; init; }

    /// <summary>The tool descriptors for the offered tools, in the same order as <see cref="OfferedToolIds"/>.</summary>
    public required IReadOnlyList<ToolDescriptor> OfferedTools { get; init; }

    /// <summary>The agent selected for this turn, or null where none was.</summary>
    public required string? AgentId { get; init; }

    /// <summary>The instruction set the turn runs under, or null where none was resolved.</summary>
    public required string? PromptId { get; init; }

    /// <summary>The caller's identity as the platform layer models it. Reaches the gateway and the meter.</summary>
    public required InvocationIdentity Identity { get; init; }

    /// <summary>The caller's turn constraints, for the tool loop's write-approval posture.</summary>
    public required TurnConstraints Constraints { get; init; }

    /// <summary>Correlates this execution with the caller's wider operation.</summary>
    public required string CorrelationId { get; init; }

    /// <summary>Makes a retry of the same logical turn safe.</summary>
    public required string IdempotencyKey { get; init; }
}

/// <summary>
/// What one governed turn execution produced, whether or not a provider was called.
/// </summary>
/// <remarks>
/// <para>
/// <b><see cref="Invoked"/> is the load-bearing member</b>, for the reason
/// <see cref="GovernedInvocationOutcome{T}"/> gives: a refused execution and an execution that reached a
/// provider and returned nothing are different facts, and a caller that cannot tell them apart reports
/// the second as the first.
/// </para>
/// <para>
/// <b>Every refusal carries the decision that produced it.</b> There is no path through this type that
/// says "it did not work" without the governance rule, the routing rejection list or the exposure rule
/// that says why — because the question an operator asks about a refused turn is which of the three
/// refused it, and the three have different remedies.
/// </para>
/// </remarks>
public sealed record GovernedTurnOutcome
{
    /// <summary>
    /// The AI Head's identity for this execution. Unique per execution, and not the request identifier.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>W7F TASK 2.</b> Minted once per call to <see cref="IGovernedTurnExecution.ExecuteAsync"/>, on
    /// every path out of it, so the identity exists even for a turn refused at the instruction set —
    /// before a route was considered. It is the member the usage ledger, the execution evidence and the
    /// audit record are all keyed by, which is why it is stated here rather than left for a reader to
    /// recover from <see cref="AuditReference"/>: the audit reference is a pointer to governance
    /// evidence, and equating the two would make the outcome a second authority for an identifier the
    /// recorder already owns.
    /// </para>
    /// <para>
    /// <b>A caller correlates by <see cref="GovernedTurnRequest.RequestId"/>, not by this.</b> The
    /// request identifier is stable across a retry and is the caller's to choose; this is minted by the
    /// AI Head and differs between two executions the caller considers the same request. A caller that
    /// stored this value and replayed its request would look for an identity that no longer exists,
    /// which is the correct outcome: the second execution is a second execution.
    /// </para>
    /// </remarks>
    public required string ExecutionId { get; init; }

    /// <summary>What governance decided about the execution as a whole.</summary>
    public required AiGovernanceDecision Decision { get; init; }

    /// <summary>True when a provider was actually called.</summary>
    public required bool Invoked { get; init; }

    /// <summary>The routing outcome, where routing ran. Null when the turn was refused before routing.</summary>
    public AiRoutingOutcome? Routing { get; init; }

    /// <summary>The exposure decision, where the exposure path ran.</summary>
    public DataExposureDecision? Exposure { get; init; }

    /// <summary>The context admitted and ranked. Empty when nothing was admitted or nothing ran.</summary>
    public IReadOnlyList<RankedContextItem> Context { get; init; } = [];

    /// <summary>The first model result, present exactly when <see cref="Invoked"/> is true.</summary>
    public ModelStepResult? Result { get; init; }

    /// <summary>The tool loop's outcome, where the loop ran.</summary>
    public ToolLoopResult? Tools { get; init; }

    /// <summary>The typed failure for a refusal, or null when the execution proceeded.</summary>
    public AiFailure? Failure { get; init; }

    /// <summary>What each stage decided, in order, for the turn trace.</summary>
    public IReadOnlyList<DecisionTrace> Decisions { get; init; } = [];

    /// <summary>
    /// The audit record written for this execution, where one was written.
    /// </summary>
    /// <remarks>
    /// <b>W7E TASK 10: this is the one direction in which the two histories reference each other.</b>
    /// The turn trace is the decision narrative a Product reads; the audit record is the governance
    /// evidence an auditor resolves an execution reference against. The trace points at the evidence
    /// and the evidence does not point back, so there is one authority for "what governance decided
    /// and what it cost" and no second copy of it that could disagree.
    /// </remarks>
    public string? AuditReference { get; init; }

    /// <summary>
    /// The failover record, where the operational plane ran.
    /// </summary>
    /// <remarks>
    /// Present on every execution the operational plane saw, including the ones where the answer was
    /// "the primary was healthy and was used". A null here means the failover plane did not run, which
    /// is a different fact from "no failover was needed" — and an operations surface that could not
    /// tell them apart would report a plane outage as a quiet period.
    /// </remarks>
    public AiFailoverDecision? Failover { get; init; }

    /// <summary>True when the execution proceeded.</summary>
    public bool IsAllowed => Decision.IsAllowed;
}

/// <summary>
/// The one path from a turn to a provider.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is W7D TASK 7.</b> Before it existed, <c>TurnPipeline</c> called <c>IModelGateway</c> after
/// choosing a model itself from a provider catalogue, through a selector that consulted no governance,
/// no registry, no classification and no requester identity. The live path was therefore the one path in
/// the estate that could reach a model without passing AI Governance — and it was the only path a
/// Product actually used.
/// </para>
/// <para>
/// <b>The order of the stages is the security property, not a preference.</b>
/// </para>
/// <list type="number">
/// <item><description><b>Instruction set.</b> Resolved first, because a turn whose agent names an unregistered instruction set must be refused before anything is routed for it — discovering its absence after routing would mean a route was selected for an execution that could never be assembled.</description></item>
/// <item><description><b>Capability and routing.</b> The turn becomes an <see cref="AiCapabilityRequest"/>, which names no route. The W7C router runs request-scope governance, then per-candidate eligibility and governance, then the operational gates, then ranking — over permitted routes only.</description></item>
/// <item><description><b>Exposure.</b> Evaluated against the destination the <em>selected</em> route would actually reach, not a destination guessed for the request. The builder then drops every source that destination does not admit, and the redactor runs where the rule requires it.</description></item>
/// <item><description><b>Ranking</b>, over admitted content only.</description></item>
/// <item><description><b>Prompt</b>, from the registered frame and the admitted context, fitted to the routed candidate's own window.</description></item>
/// <item><description><b>Governed invocation, with governed failover.</b> The full governance request — route, destination, agent, prompt version, tool identifiers, predicted cost — is evaluated synchronously, and the provider delegate is reached only on an allow. When a permitted call fails, the next route is drawn from the router's own fallback chain and re-evaluated before it is used.</description></item>
/// <item><description><b>Tool loop</b>, reached only because a provider call was permitted, and re-entering the gate for each further model round.</description></item>
/// <item><description><b>Recording.</b> One operational entry per provider call, one reliability observation per call, one evidence record and one audit record per execution — written once, after every stage has finished, on every path out including the refusals.</description></item>
/// </list>
/// <para>
/// <b>It holds no credential, no client and no endpoint.</b> Its collaborators are read-only registries,
/// the governance engine, the exposure path, the operational plane and the platform's gateway
/// abstractions. The credential belongs to the provider adapter below <see cref="IModelGateway"/>, where
/// it always was.
/// </para>
/// </remarks>
public interface IGovernedTurnExecution
{
    /// <summary>Executes a turn through the governed path, or returns the refusal that stopped it.</summary>
    Task<GovernedTurnOutcome> ExecuteAsync(GovernedTurnRequest request, CancellationToken ct = default);
}

/// <summary>
/// The governed path, composed from the W7B, W7C, W7D and W7E pieces.
/// </summary>
/// <remarks>
/// <para>
/// See <see cref="IGovernedTurnExecution"/> for the stage order and why each stage is where it is. This
/// type composes that order and holds no policy of its own: every table it consults arrives through a
/// constructor argument, and the only decisions it takes are about sequence.
/// </para>
/// <para>
/// <b>W7E added two things and changed no stage's authority.</b> The operational plane is consulted for
/// every recorded fact — usage, cost, reliability, audit — and the failover selector is consulted after
/// a permitted call fails. Neither can permit anything: the operational gate refuses and the selector
/// only ever chooses among routes the router already admitted, so the governance engine above them
/// remains the thing that decides whether work may run at all.
/// </para>
/// </remarks>
public sealed class GovernedTurnExecution : IGovernedTurnExecution
{
    /// <summary>The runaway bound on tool calls, stated to governance rather than held only in the loop.</summary>
    private const int MaxToolCalls = 5;

    private readonly IAiCapabilityRouter _router;
    private readonly IAiGovernanceEvaluator _governance;
    private readonly IDataExposurePolicyEvaluator _exposure;
    private readonly DataExposurePolicy _exposurePolicy;
    private readonly IContextBuilder _contextBuilder;
    private readonly IContextRedactor _redactor;
    private readonly IContextSelector _contextSelector;
    private readonly IAiPromptRegistry _prompts;
    private readonly IAiToolRegistry _tools;
    private readonly IPromptStep _promptStep;
    private readonly IModelStep _modelStep;
    private readonly IToolLoop _toolLoop;
    private readonly IAiFailoverSelector _failovers;
    private readonly AiOperationsRecorder _recorder;
    private readonly IAiExecutionIdSource _executionIds;
    private readonly TimeProvider _time;

    /// <summary>Composes the governed path.</summary>
    public GovernedTurnExecution(
        IAiCapabilityRouter router,
        IAiGovernanceEvaluator governance,
        IDataExposurePolicyEvaluator exposure,
        DataExposurePolicy exposurePolicy,
        IContextBuilder contextBuilder,
        IContextRedactor redactor,
        IContextSelector contextSelector,
        IAiPromptRegistry prompts,
        IAiToolRegistry tools,
        IPromptStep promptStep,
        IModelStep modelStep,
        IToolLoop toolLoop,
        IAiFailoverSelector failovers,
        AiOperationsRecorder recorder,
        IAiExecutionIdSource executionIds,
        TimeProvider time)
    {
        ArgumentNullException.ThrowIfNull(router);
        ArgumentNullException.ThrowIfNull(governance);
        ArgumentNullException.ThrowIfNull(exposure);
        ArgumentNullException.ThrowIfNull(exposurePolicy);
        ArgumentNullException.ThrowIfNull(contextBuilder);
        ArgumentNullException.ThrowIfNull(redactor);
        ArgumentNullException.ThrowIfNull(contextSelector);
        ArgumentNullException.ThrowIfNull(prompts);
        ArgumentNullException.ThrowIfNull(tools);
        ArgumentNullException.ThrowIfNull(promptStep);
        ArgumentNullException.ThrowIfNull(modelStep);
        ArgumentNullException.ThrowIfNull(toolLoop);
        ArgumentNullException.ThrowIfNull(failovers);
        ArgumentNullException.ThrowIfNull(recorder);
        ArgumentNullException.ThrowIfNull(executionIds);
        ArgumentNullException.ThrowIfNull(time);

        _router = router;
        _governance = governance;
        _exposure = exposure;
        _exposurePolicy = exposurePolicy;
        _contextBuilder = contextBuilder;
        _redactor = redactor;
        _contextSelector = contextSelector;
        _prompts = prompts;
        _tools = tools;
        _promptStep = promptStep;
        _modelStep = modelStep;
        _toolLoop = toolLoop;
        _failovers = failovers;
        _recorder = recorder;
        _executionIds = executionIds;
        _time = time;
    }

    /// <inheritdoc />
    public async Task<GovernedTurnOutcome> ExecuteAsync(
        GovernedTurnRequest request,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        // W7F TASK 2: the execution identity is minted here, once, before any stage runs. Minting it in
        // the recording rather than at the point it is first written is what makes it true of every path
        // out of the stage sequence — including the refusal at the instruction set, which returns before
        // a route exists and which the audit record still has to be resolvable for.
        //
        // The caller's request identifier is NOT used and must not be. It is stable across a retry by
        // design, and the two stores that key on this value replace on collision, so writing the request
        // identifier here is what made a replayed request overwrite its predecessor's evidence (W7E
        // CF-9). See IAiExecutionIdSource for the behaviour this establishes.
        var recording = new ExecutionRecording
        {
            ExecutionId = _executionIds.Next(),
            StartTimestamp = _time.GetTimestamp(),
        };

        var outcome = await ExecuteCoreAsync(request, recording, ct).ConfigureAwait(false);

        // One recording site, reached by every path out of the stage sequence. An audit record emitted
        // from each of the five return statements would be a record whose presence depended on which
        // branch was taken — and the branch that would be missed is the refusal, which is the one an
        // auditor most wants to resolve.
        return Record(request, recording, outcome);
    }

    /// <summary>
    /// The stage sequence, with everything it learns accumulating into the recording.
    /// </summary>
    /// <remarks>
    /// Split out from <see cref="ExecuteAsync"/> so that there is exactly one place the audit and the
    /// operational records are written, and it is not on any branch of this method. Every <c>return</c>
    /// below is a statement about what the turn was refused or produced; none of them is a statement
    /// about what was recorded, because none of them records.
    /// </remarks>
    private async Task<GovernedTurnOutcome> ExecuteCoreAsync(
        GovernedTurnRequest request,
        ExecutionRecording recording,
        CancellationToken ct)
    {
        var decisions = new List<DecisionTrace>();

        // ---- STAGE 1: the instruction set ---------------------------------------------------------
        if (!TryResolveInstructionSet(request.PromptId, out var prompt, out var promptFailure))
        {
            var refusal = AiGovernanceDecision.Block(
                AiGovernanceRules.PromptUnregistered,
                promptFailure!,
                AiFailureCategory.PolicyBlocked,
                AiGovernanceRules.PromptUnregistered);

            decisions.Add(new DecisionTrace("Refused the turn at the instruction set", promptFailure!, []));

            return Refused(recording.ExecutionId, refusal, request.CorrelationId, decisions);
        }

        recording.PromptVersion = prompt?.Version;

        if (prompt is not null)
        {
            decisions.Add(new DecisionTrace(
                $"Resolved instruction set '{prompt.PromptId}' at version '{prompt.Version}'",
                $"Owned by {prompt.Owner}. {prompt.Purpose}",
                []));
        }

        // ---- STAGE 2: the semantic request, and the route it is permitted -------------------------
        var classifications = DeclaredClassifications(request.Context);
        var profile = ProfileFor(request);

        var capabilityRequest = new AiCapabilityRequest
        {
            // Stated by the caller rather than chosen here. TurnIntent is not a capability — it says what
            // the caller wants done with the answer, and it drives agent selection and the response
            // contract. Mapping intents onto capabilities would be inventing a capability vocabulary per
            // caller need, which is the opposite of the semantic model W7A built: the caller asks for a
            // capability, and the registry decides what serves it.
            Capability = request.Capability,
            Purpose = request.Purpose,
            Requester = request.Requester,
            Input = request.Input,
            Context = request.Context,
            Classification = request.Classification,
            Execution = request.Execution,
            Tools = profile,
            CorrelationId = request.CorrelationId,
            IdempotencyKey = request.IdempotencyKey,
            RequestId = request.RequestId,
        };

        // The tool identifiers are stated to the router as well as the profile, because they answer
        // different questions: the profile is what the caller permits, the identifiers are what the
        // execution will attempt. Leaving the identifiers out would route an execution whose specific
        // tool permissions were never evaluated — see AiRoutingContext.RequestedToolIds.
        var routingContext = new AiRoutingContext
        {
            InputTokens = EstimateInputTokens(request),
            OutputTokens = 0,
            ContextClassifications = classifications,
            RequestedToolIds = request.OfferedToolIds,
        };

        // Recorded once here and read by every invocation record below, so the tier an execution is
        // attributed to is the tier the routing decision was taken under rather than a second value
        // derived later from the same source.
        recording.Tier = routingContext.ProcessingTier;

        var routing = _router.Route(
            capabilityRequest,
            AiPlatformGovernanceAttestation.NotApplicable,
            routingContext);

        decisions.Add(RoutingTrace(routing));

        if (!routing.IsRouted || routing.Selected is null)
        {
            return new GovernedTurnOutcome
            {
                ExecutionId = recording.ExecutionId,
                Decision = routing.Governance,
                Invoked = false,
                Routing = routing,
                Failure = routing.Failure,
                Decisions = decisions,
            };
        }

        var candidate = routing.Selected;

        // ---- STAGE 3: what may reach the destination this route actually uses ---------------------
        var exposureDecision = _exposure.Evaluate(
            request.Classification,
            classifications,
            candidate.Destination);

        decisions.Add(new DecisionTrace(
            $"Evaluated data exposure for a '{candidate.Destination}' destination",
            exposureDecision.Allowed
                ? $"Classified '{request.Classification}'; context ceiling '{exposureDecision.ContextCeiling}'; "
                  + (exposureDecision.RequiresRedaction ? "redaction required" : "no redaction required")
                : exposureDecision.Reason ?? "The exposure policy refused the destination.",
            [.. exposureDecision.RulesApplied]));

        if (!exposureDecision.Allowed)
        {
            // The router's per-candidate governance pass already ran this evaluator against this same
            // destination, so a refusal here means the two agree — and the assertion is that they must.
            // Reaching this branch with a route governance permitted would mean the exposure table
            // answered two ways for one request, which is what the single-evaluator arrangement exists
            // to make impossible.
            return new GovernedTurnOutcome
            {
                ExecutionId = recording.ExecutionId,
                Decision = routing.Governance.Combine(AiGovernanceDecision.Block(
                    AiGovernanceRules.ExposureBlocked,
                    exposureDecision.Reason ?? "The request's classification forbids this destination.",
                    AiFailureCategory.DataExposureBlocked,
                    AiGovernanceRules.ExposureBlocked)),
                Invoked = false,
                Routing = routing,
                Exposure = exposureDecision,
                Failure = exposureDecision.ToFailure(request.CorrelationId),
                Decisions = decisions,
            };
        }

        var built = _contextBuilder.Build(request.Context, exposureDecision, _exposurePolicy);

        if (built.IsPartial)
        {
            decisions.Add(new DecisionTrace(
                $"Withheld {built.Excluded.Count} context item(s) from the execution",
                "Each was classified above what the selected destination admits. Nothing was truncated: an "
                + "excluded item is excluded whole, because a truncated item reads as a short document "
                + "rather than as a withheld one.",
                [.. built.Excluded.Select(excluded => excluded.ContextItemId)]));
        }

        // Redaction runs AFTER filtering and BEFORE ranking, so a redacted body is what is ranked, what
        // is assembled and what is sent. Redacting after assembly would redact a string already shaped
        // by content that never left.
        var admitted = exposureDecision.RequiresRedaction
            ? _redactor.Redact(built.Bundle)
            : built.Bundle;

        // What the audit record carries is a reference to each admitted item and, where the
        // classification permits it, a digest of what was sent — never the content. The digest is taken
        // here, over the post-redaction bundle, so the record names what actually travelled.
        recording.ContextReferences = AiContextDigest.RefsFor(admitted.Items);

        // ---- STAGE 4: ranking, over admitted content only -----------------------------------------
        var selection = _contextSelector.Select(admitted, request.Input.Text);
        decisions.Add(selection.Decision);

        // ---- STAGE 5: the prompt ------------------------------------------------------------------
        var assembled = _promptStep.Assemble(
            request.Input,
            selection.Ranked,
            candidate.Model.MaxContextTokens ?? 0,
            prompt?.SystemFrame ?? string.Empty,
            request.OfferedTools);

        decisions.Add(assembled.Decision);

        // ---- STAGE 6: the governed invocation, with governed failover -----------------------------
        //
        // The loop is the failover. Each turn of it is one governance question and, if permitted, one
        // provider call. The selector is consulted only after a call governance permitted and the
        // provider did not complete, so the chain is never searched for a way around a refusal — and it
        // can only return routes the router already admitted, because the chain is the router's own.
        var attempted = new List<AiFailoverAttempt>();
        var considered = new List<AiFailoverAttempt>();

        var primary = candidate;
        var route = RouteFor(request, capabilityRequest, profile, classifications, prompt, candidate, 0, isFallback: false);
        RouteOutcome call;

        while (true)
        {
            call = await InvokeAsync(request, recording, route, assembled.Prompt, ct)
                .ConfigureAwait(false);

            recording.Absorb(route, call);

            var attempt = AttemptFor(route, call);
            considered.Add(attempt);

            // Only a route that was actually invoked counts as attempted. Reporting a gate-refused route
            // to the selector would make it describe that route as "already attempted and failed" the
            // next time it walked the chain, which is a different fact from "policy refused it".
            if (call.Invoked)
            {
                attempted.Add(attempt);
            }

            decisions.Add(InvocationTrace(route, call));

            if (call.Invoked && call.Result?.Result.Success is true)
            {
                break;
            }

            if (!call.Invoked)
            {
                // The invocation gate refused. No alternate is sought and none is offered: a refusal is
                // not a route failure, and the failover record says so in the estate's own vocabulary
                // rather than leaving a reader to infer a quiet period from a null.
                return new GovernedTurnOutcome
                {
                    ExecutionId = recording.ExecutionId,
                    Decision = routing.Governance.Combine(call.Decision),
                    Invoked = false,
                    Routing = routing,
                    Exposure = exposureDecision,
                    Context = selection.Ranked,
                    Failure = call.Failure,
                    Decisions = decisions,
                    Failover = new AiFailoverDecision
                    {
                        Primary = primary,
                        Attempts = considered,
                        Selected = null,
                        ReasonCode = AiFailoverReasonCode.GovernanceBlockNotFailover,
                        Reason = "The governed invocation gate refused this route, so no alternate was "
                            + "sought. The fallback chain is searched for operational failures, never for "
                            + "a way around a refusal.",
                    },
                };
            }

            // The semantic request, not the turn request: the selector re-reads the operational gates
            // from the same identity and scope the router evaluated them against, and AiCapabilityRequest
            // is the shape that carries them.
            var step = _failovers.Next(
                capabilityRequest, routingContext, routing, attempted, call.Failure, _time.GetUtcNow());

            foreach (var skip in step.Skipped)
            {
                // One row per route. A later round re-walks the chain from the top, so a member refused
                // earlier arrives again — carrying the less informative reason "already attempted". The
                // first record of why it was refused is the one an operator needs.
                if (!considered.Any(existing =>
                    string.Equals(existing.ModelId, skip.ModelId, StringComparison.Ordinal)
                    && string.Equals(existing.ProviderId, skip.ProviderId, StringComparison.Ordinal)))
                {
                    considered.Add(skip);
                }
            }

            if (step.Candidate is not { } next)
            {
                decisions.Add(new DecisionTrace(
                    $"Stopped the failover after {attempted.Count} attempt(s)",
                    step.Detail,
                    [.. considered.Select(entry => $"{entry.ModelId}:{entry.ReasonCode}")]));

                return new GovernedTurnOutcome
                {
                    ExecutionId = recording.ExecutionId,
                    Decision = routing.Governance.Combine(call.Decision),
                    Invoked = true,
                    Routing = routing,
                    Exposure = exposureDecision,
                    Context = selection.Ranked,
                    Result = call.Result,
                    Failure = call.Failure ?? AiFailure.From(
                        AiFailureCategory.ProviderUnavailable,
                        "routing.failover-exhausted",
                        step.Detail,
                        request.CorrelationId),
                    Decisions = decisions,
                    Failover = new AiFailoverDecision
                    {
                        Primary = primary,
                        Attempts = considered,
                        Selected = null,
                        ReasonCode = step.ReasonCode,
                        Reason = step.Detail,
                    },
                };
            }

            decisions.Add(new DecisionTrace(
                $"Failing over to '{next.ModelId}' on provider '{next.ProviderId}'",
                step.Detail,
                [.. step.Skipped.Select(skip => $"{skip.ModelId}:{skip.ReasonCode}")]));

            // The governance request is rebuilt for the route being attempted, from that route's own
            // model, provider and predicted cost. Reusing the primary's would ask governance to permit
            // one route and then invoke another under the answer.
            route = RouteFor(
                request, capabilityRequest, profile, classifications, prompt, next,
                OrderOf(next, routing), isFallback: true, operational: step.Operational);
        }

        // ---- STAGE 7: tools, reached only because a provider call was permitted --------------------
        var toolLoop = await _toolLoop.RunAsync(
            call.Result!.Result,
            assembled.Prompt,
            request.OfferedTools,
            ToolVerdict(profile),
            request.Constraints,
            request.Identity,
            (messages, token) => ContinueUnderGovernanceAsync(
                request, route, recording, messages, token),
            ct).ConfigureAwait(false);

        decisions.AddRange(toolLoop.Decisions);
        recording.NoteTools(toolLoop.InvokedToolIds);

        return new GovernedTurnOutcome
        {
            ExecutionId = recording.ExecutionId,
            Decision = routing.Governance.Combine(call.Decision),
            Invoked = true,
            Routing = routing,
            Exposure = exposureDecision,
            Context = selection.Ranked,
            Result = call.Result,
            Tools = toolLoop,
            Decisions = decisions,
            Failover = route.IsFallback
                ? new AiFailoverDecision
                {
                    Primary = primary,
                    Attempts = considered,
                    Selected = route.Candidate,
                    ReasonCode = AiFailoverReasonCode.AlternateSucceeded,
                    Reason = $"The primary route did not complete and fallback step {route.Order} served the "
                        + "request. Governance permitted this route for this request when the chain was "
                        + "built, and it was re-checked against live health and cost before it was used.",
                }
                : AiFailoverDecision.NotNeeded(primary, _time.GetUtcNow()),
        };
    }

    /// <summary>
    /// Asks the model for another round, under a fresh governance decision.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Every round is a separate question, and this is where that is answered.</b> The tool loop used
    /// to hold a model gateway and re-invoke directly, so a governed first call could be followed by up
    /// to four ungoverned ones. The loop can now only reach the model through this method, and this
    /// method re-evaluates before it calls.
    /// </para>
    /// <para>
    /// <b>A refused round ends the loop with what the conversation has.</b> It does not throw and it does
    /// not degrade to calling anyway. A failed model result is the loop's existing stop condition, so
    /// returning one is how the refusal becomes a stop without this method having to reach into the
    /// loop's control flow — and the refusal is in the trace, which is the property that matters: a
    /// silently truncated agent loop is indistinguishable from a model that stopped asking for tools.
    /// </para>
    /// <para>
    /// <b>The round is priced at the first round's estimate rather than a fabricated one.</b> Pricing the
    /// fourth call would require knowing what the third returned, which is not knowable before it runs.
    /// What it actually consumed is measured and recorded, per call, by <see cref="InvokeAsync"/> — so
    /// the bound on the gate is a prediction and the record of the spend is a measurement.
    /// </para>
    /// </remarks>
    private async Task<ModelStepResult> ContinueUnderGovernanceAsync(
        GovernedTurnRequest request,
        ActiveRoute route,
        ExecutionRecording recording,
        IReadOnlyList<ModelMessage> messages,
        CancellationToken ct)
    {
        var call = await InvokeAsync(request, recording, route, new AssembledPrompt(messages, [], 0), ct)
            .ConfigureAwait(false);

        recording.Absorb(route, call);

        // A failed continuation is never recovered — the loop stops on it — so its category is the
        // execution's. Recorded here rather than inferred later from a bare status, because "the run was
        // degraded" and "the run was degraded because a governance gate stopped the fourth round" lead
        // to different investigations.
        if (call.Failure is { } failure)
        {
            recording.FailureCategory ??= failure.Category;
        }

        if (call.Invoked && call.Result is not null)
        {
            return call.Result;
        }

        var reason = call.Failure?.Message ?? "The governed invocation gate refused this round.";

        return FailedRound(reason)
            with
            {
                Decision = new DecisionTrace(
                    "Stopped the tool loop at the governed invocation gate",
                    reason,
                    [.. call.Decision.RulesApplied]),
            };
    }

    /// <summary>A model result that reports a failure, for the loop to stop on.</summary>
    private static ModelStepResult FailedRound(string reason) => new(
        new ModelInvocationResult { Success = false, Error = reason },
        new DecisionTrace("Stopped the tool loop at the governed invocation gate", reason, []));

    /// <summary>
    /// One governed attempt: the gate, then the provider call, then the record of what it consumed.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>The usage entry is written here rather than by the caller, because "one entry per provider
    /// invocation" has to be true of the place the invocation happens.</b> A caller that recorded what it
    /// believed had happened would be a second account of the same call, and the two would disagree the
    /// first time either was edited. There is exactly one call site in this type that reaches
    /// <see cref="IModelStep"/> and it is below the gate.
    /// </para>
    /// <para>
    /// <b>Nothing is recorded for a call that did not happen.</b> A usage entry for a refused invocation
    /// would be spend the estate cannot reconcile against any provider's account, and an entry for a
    /// refused call is indistinguishable from one for a call that returned nothing.
    /// </para>
    /// <para>
    /// <b>The attempt identity is taken after the gate, so it numbers the calls that happened.</b> A
    /// refused invocation consumes no ordinal: the ledger's attempts for one execution are then
    /// one-through-N with no gaps, and "attempt two" means "the second call this execution made" rather
    /// than "the second time it asked", which is a fact the execution evidence already records per route
    /// and which the ledger has no field to explain. The tier is read from the recording for the reason
    /// the recording gives — one write of the routing decision's tier, read everywhere it is attributed.
    /// </para>
    /// </remarks>
    private async Task<RouteOutcome> InvokeAsync(
        GovernedTurnRequest request,
        ExecutionRecording recording,
        ActiveRoute route,
        AssembledPrompt prompt,
        CancellationToken ct)
    {
        var started = _time.GetTimestamp();

        var invocation = await GovernedProviderInvocation.InvokeAsync(
            _governance,
            route.GovernanceRequest,
            AiPlatformGovernanceAttestation.NotApplicable,
            token => _modelStep.InvokeAsync(
                prompt,
                route.Candidate.ModelId,
                request.OfferedTools,
                request.Identity,
                request.Execution.MaxCost,
                token),
            ct).ConfigureAwait(false);

        if (!invocation.Invoked || invocation.Result is null)
        {
            return new RouteOutcome(
                invocation.Decision,
                Invoked: false,
                Result: null,
                Failure: invocation.ToFailure(request.CorrelationId),
                Entry: null,
                Latency: null,
                At: _time.GetUtcNow());
        }

        var result = invocation.Result.Result;
        var latency = _time.GetElapsedTime(started);
        var at = _time.GetUtcNow();
        var attemptId = recording.NextAttemptId();

        var entry = _recorder.RecordInvocation(new AiInvocationFacts
        {
            // The execution's own identity, not the caller's request identifier. This is the CF-9
            // correction: the request identifier is stable across a retry and the ledger and the audit
            // sink both replace on a key collision, so writing it here made a replayed request overwrite
            // its predecessor's evidence.
            ExecutionId = recording.ExecutionId,
            AttemptId = attemptId,
            RequestId = request.RequestId,
            CorrelationId = request.CorrelationId,
            Capability = request.Capability,
            Requester = request.Requester,
            ModelId = route.Candidate.ModelId,
            ProviderId = route.Candidate.ProviderId,
            Tier = recording.Tier,
            IsFallback = route.IsFallback,
            // FROM THE STEP RESULT, NOT THE PLATFORM RESULT. `result.Usage` is non-nullable and
            // defaults to zero, so reading it here recorded a fabricated 0 for every call whose
            // provider reported no usage — and the cost basis below is derived from these counts, so
            // that 0 became a "measured" cost of nothing. invocation.Result carries the true
            // measurement, null when there was none.
            TokensIn = invocation.Result.TokensIn,
            TokensOut = invocation.Result.TokensOut,

            // The prediction the budget decision rested on, carried beside the measurement rather than
            // replaced by it. Which of the two is authoritative is the ledger entry's own business —
            // see AiCostBasis — and the pair is what lets the estate ask whether its rates are right.
            PreInvocationEstimate = route.Candidate.EstimatedCost,
            Currency = route.Candidate.CostCurrency,
            Succeeded = result.Success,

            // W7G.1 Gate 7: the category recorded against the ledger entry is the one the provider seam
            // classified, translated into this Head's vocabulary, rather than the single
            // ProviderUnavailable every provider-reported failure used to collapse into. An adapter that
            // does not classify still yields ProviderUnavailable - see ModelFailureMap - so the ledger
            // gains precision without any existing producer changing meaning.
            FailureCategory = result.Success ? null : ModelFailureMap.ToCategory(result.Failure),
            Latency = latency,
            At = at,
        });

        return new RouteOutcome(
            invocation.Decision,
            Invoked: true,
            Result: invocation.Result,
            Failure: result.Success ? null : ProviderFailure(route, request.CorrelationId, result.Failure),
            Entry: entry,
            Latency: latency,
            At: at);
    }

    /// <summary>The typed failure for a call that was permitted and did not complete.</summary>
    /// <remarks>
    /// <para>
    /// <b>The category is the seam's, translated — not this method's invention.</b> Before W7G.1 the
    /// provider seam carried only free text, so nothing above it could tell a deadline from a rejected
    /// credential from a retired model, and this method had one category to give and gave it: every
    /// provider-reported failure arrived at the caller as
    /// <see cref="AiFailureCategory.ProviderUnavailable"/>. The seam now classifies, so the category
    /// travels rather than being assumed. Where a producer does not classify — an adapter older than the
    /// member, or a status with no honest target — <see cref="ModelFailureMap.ToCategory"/> yields
    /// <see cref="AiFailureCategory.ProviderUnavailable"/>, which is exactly what this method returned
    /// unconditionally before, so nothing that used to be reported differently is.
    /// </para>
    /// <para>
    /// <b>The category and the message are two channels and only one of them is prose.</b> The category
    /// is a value from a closed set that a caller may branch on; the message below is a fixed,
    /// provider-free sentence. Neither is derived from the provider's own report.
    /// </para>
    /// <para>
    /// <b>THE PROVIDER'S OWN ERROR TEXT IS DELIBERATELY NOT REPRODUCED HERE, AND MUST NOT BE.</b>
    /// This message crosses the Gateway to the caller in
    /// <c>AiCapabilityResponse.Failure.Message</c>, and <see cref="AiFailure.Message"/> is documented
    /// as caller-safe and "never a provider error body" — an upstream message can carry a model name,
    /// an endpoint, a region or a request id, any of which re-leaks exactly what the boundary exists to
    /// contain.
    /// </para>
    /// <para>
    /// The field it was previously taken from is free text by construction. The real
    /// <c>OpenAIModelGateway</c> assigns <c>ex.Message</c> from its catch block, and
    /// <c>RoutingModelGateway</c> writes a sentence naming the model identifier, so interpolating that
    /// field — as an earlier revision of this method did — put a vendor SDK's exception text on the wire
    /// to a consumer. Nothing is lost for operators by dropping it: each adapter appends the same text
    /// to its own audit record before returning, which is where an operator entitled to it reads it.
    /// The typed, caller-safe facts stay here; the provider's vocabulary does not.
    /// </para>
    /// <para>
    /// <b>The classification is not a channel for the text either.</b>
    /// <see cref="OpenAIFailureClassifier"/> reads an exception's type and its transport status and
    /// never its message, so the typed field cannot become a slower route for the same leak — a
    /// classifier that pattern-matched vendor prose would reintroduce exactly what the paragraph above
    /// forbids, one layer down and harder to see.
    /// </para>
    /// </remarks>
    private static AiFailure ProviderFailure(
        ActiveRoute route,
        string correlationId,
        ModelFailureKind? classification) => AiFailure.From(
            ModelFailureMap.ToCategory(classification),
            "routing.provider-invocation-failed",
            $"The governed call to '{route.Candidate.ModelId}' on provider "
                + $"'{route.Candidate.ProviderId}' was permitted and did not succeed. The provider's own "
                + "report of why is held on the provider's audit record and is not reproduced to the "
                + "caller, because a provider's error text is the provider's vocabulary.",
            correlationId);

    /// <summary>
    /// Pairs a route with the governance question asked about it and its place in the sequence.
    /// </summary>
    /// <remarks>
    /// Called once per attempt rather than once per execution, because the governance request names the
    /// model, the provider and the predicted cost — all three of which change when the route does. A
    /// fallback invoked under the primary's request would be work governance permitted for a different
    /// route.
    /// </remarks>
    private static ActiveRoute RouteFor(
        GovernedTurnRequest request,
        AiCapabilityRequest capabilityRequest,
        ToolPermissionProfile profile,
        IReadOnlyList<DataClassification> classifications,
        AiPromptRegistration? prompt,
        AiRoutingCandidate candidate,
        int order,
        bool isFallback,
        AiOperationalVerdict? operational = null) => new(
            candidate,
            BuildGovernanceRequest(
                request,
                capabilityRequest.Capability,
                profile,
                classifications,
                candidate,
                prompt,
                candidate.EstimatedCost),
            order,
            isFallback,
            operational);

    /// <summary>Builds the invocation-time governance request for a routed candidate.</summary>
    private static AiGovernanceEvaluationRequest BuildGovernanceRequest(
        GovernedTurnRequest request,
        CapabilityId capability,
        ToolPermissionProfile profile,
        IReadOnlyList<DataClassification> classifications,
        AiRoutingCandidate candidate,
        AiPromptRegistration? prompt,
        decimal? estimatedCost) => new()
        {
            RequestId = request.RequestId,
            Capability = capability,
            Requester = request.Requester,
            Classification = request.Classification,
            ContextClassifications = classifications,
            Destination = candidate.Destination,
            Execution = request.Execution,
            Tools = profile,
            RequestedToolIds = request.OfferedToolIds,
            ModelId = candidate.ModelId,
            ProviderId = candidate.ProviderId,
            AgentId = request.AgentId,
            PromptId = prompt?.PromptId,
            PromptVersion = prompt?.Version,
            EstimatedCost = estimatedCost,
            CorrelationId = request.CorrelationId,
            Purpose = request.Purpose,
        };

    /// <summary>
    /// A route's position in the whole attempt sequence, primary first.
    /// </summary>
    /// <remarks>
    /// Derived from the fallback chain rather than counted locally, because the selector walks past the
    /// members it refuses. A local counter would number the first usable chain member 1 while the
    /// refusals it skipped were numbered 1, 2 and 3 — and two steps of a failover recorded with the same
    /// order make the sequence unreconstructable, which is the only thing the field is for.
    /// </remarks>
    private static int OrderOf(AiRoutingCandidate candidate, AiRoutingOutcome routing)
    {
        for (var index = 0; index < routing.FallbackChain.Count; index++)
        {
            var member = routing.FallbackChain[index];

            if (string.Equals(member.ModelId, candidate.ModelId, StringComparison.Ordinal)
                && string.Equals(member.ProviderId, candidate.ProviderId, StringComparison.Ordinal))
            {
                return index + 1;
            }
        }

        // Unreachable: the only source of an alternate is the chain. Ordered past every member rather
        // than thrown over, because an execution that has already reached a provider must not fail on a
        // record-ordering detail.
        return routing.FallbackChain.Count + 1;
    }

    /// <summary>The failover record for one turn of the loop.</summary>
    /// <remarks>
    /// The provider's own error text is deliberately not copied here. This record is durable operational
    /// evidence, and a provider error body is the one field most likely to carry something the estate
    /// should not keep; the typed category and code are what an operator routes an investigation with,
    /// and the full failure travels on the outcome where the caller can see it.
    /// </remarks>
    private AiFailoverAttempt AttemptFor(ActiveRoute route, RouteOutcome call)
    {
        if (!call.Invoked)
        {
            return new AiFailoverAttempt
            {
                Order = route.Order,
                ModelId = route.Candidate.ModelId,
                ProviderId = route.Candidate.ProviderId,
                Outcome = AiFailoverAttemptOutcome.Rejected,
                ReasonCode = AiFailoverReasonCode.GovernanceBlockNotFailover,
                Detail = $"The governed invocation gate refused this route: "
                    + (call.Decision.Reason ?? "no reason was recorded"),
                Governance = call.Decision,
                At = call.At,
            };
        }

        var succeeded = call.Result?.Result.Success is true;

        return new AiFailoverAttempt
        {
            Order = route.Order,
            ModelId = route.Candidate.ModelId,
            ProviderId = route.Candidate.ProviderId,
            Outcome = succeeded
                ? route.IsFallback
                    ? AiFailoverAttemptOutcome.AlternateSucceeded
                    : AiFailoverAttemptOutcome.PrimarySucceeded
                : AiFailoverAttemptOutcome.Attempted,
            ReasonCode = succeeded
                ? route.IsFallback
                    ? AiFailoverReasonCode.AlternateSucceeded
                    : AiFailoverReasonCode.HealthyRoute
                : AiFailoverReasonCode.AlternateFailed,
            Detail = succeeded
                ? $"The call was permitted and completed as the {(route.IsFallback ? $"fallback step {route.Order}" : "primary route")}."
                : $"The call was permitted and did not complete. {call.Failure?.Category} "
                    + $"({call.Failure?.Code}).",

            // The verdict that permitted this call, carried on the attempt record as it is on the
            // refused branch above. It was absent here and its absence was not a deliberate silence:
            // this record is the one an operator reads AFTER the fact, through the operations surface,
            // and without the decision the surface could say a route was called and not who permitted
            // it — while the same decision was already in hand on this line, used two lines below for
            // the trace. W7G-R added it, so that a fallback's attempt is as traceable to a verdict as a
            // primary's, which is what W7G's cost-and-audit proof requires of both.
            Governance = call.Decision,

            // And the operational evidence it was admitted on, on the same argument and one step
            // further. A chain member the selector REFUSED carried its budget decision and its
            // reliability evidence; a member it ADMITTED carried neither, so the estate could say what
            // a fallback was refused for and not what it was allowed to spend. That is the wrong way
            // round: a refused route costs nothing and an admitted one is about to be called. The
            // verdict is null for the primary, which the router admitted rather than the selector and
            // whose own evidence travels on the execution, and null for a route reached without the
            // selector at all.
            Budget = route.Operational?.Budget,
            Reliability = route.Operational?.Reliability,
            At = call.At,
        };
    }

    /// <summary>The trace line for one attempt.</summary>
    private static DecisionTrace InvocationTrace(ActiveRoute route, RouteOutcome call)
    {
        var role = route.IsFallback ? $"fallback step {route.Order}" : "the primary route";

        if (!call.Invoked)
        {
            return new DecisionTrace(
                $"Governance refused the invocation of route '{route.Candidate.ModelId}'",
                call.Decision.Reason ?? "The governed invocation gate returned no reason.",
                [.. call.Decision.RulesApplied]);
        }

        return call.Result?.Result.Success is true
            ? new DecisionTrace(
                $"Invoked route '{route.Candidate.ModelId}' on provider '{route.Candidate.ProviderId}'",
                $"Selected by the router as {role} with score {route.Candidate.Score} to a "
                    + $"'{route.Candidate.Destination}' destination",
                [.. call.Decision.RulesApplied])
            : new DecisionTrace(
                $"Route '{route.Candidate.ModelId}' on provider '{route.Candidate.ProviderId}' did not complete",
                $"The call was permitted and the provider did not succeed. {call.Failure?.Category} "
                    + $"({call.Failure?.Code}).",
                [.. call.Decision.RulesApplied]);
    }

    /// <summary>
    /// Writes the execution's operational records and stamps the audit reference onto the outcome.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Tokens and cost are totalled from the recorded entries, not from the tool loop's accumulator.</b>
    /// The two cover the same calls — the accumulator excludes the first result, and the first result is
    /// the one entry the loop never records — so adding both would count every continuation twice. The
    /// entries are also the ledger's own record, which is what makes an execution's total in its audit
    /// record always reconcile with what the usage ledger reports for that execution.
    /// </para>
    /// <para>
    /// <b>The result reference is left unset, and on purpose.</b>
    /// <see cref="TurnTrace.AuditReference"/> is the join in this lane: the trace points at the evidence.
    /// Naming the trace here would make each point at the other, which is two records claiming to be the
    /// other's index — and the audit record is written before the trace exists.
    /// </para>
    /// </remarks>
    private GovernedTurnOutcome Record(
        GovernedTurnRequest request,
        ExecutionRecording recording,
        GovernedTurnOutcome outcome)
    {
        var audit = _recorder.RecordExecution(new AiExecutionFacts
        {
            // The execution's own identity. The audit sink and the evidence store are both keyed on it
            // and both replace on collision, so this is the member that decides whether two executions
            // under one request identifier keep two records or one — see IAiExecutionIdSource.
            ExecutionId = recording.ExecutionId,
            RequestId = request.RequestId,
            CorrelationId = request.CorrelationId,
            Requester = request.Requester,
            Capability = request.Capability,
            Purpose = request.Purpose,
            Classification = request.Classification,
            Tier = recording.Tier,
            ContextReferences = recording.ContextReferences,
            ProviderUsed = recording.ProviderUsed,
            ModelUsed = recording.ModelUsed,
            PromptVersion = recording.PromptVersion,
            ToolsInvoked = recording.ToolsInvoked,
            TokensIn = recording.TokensIn,
            TokensOut = recording.TokensOut,
            Cost = recording.Cost.Amount,
            Currency = recording.Cost.AmountCurrency,
            CostBasis = recording.Cost.Basis,
            Latency = _time.GetElapsedTime(recording.StartTimestamp),
            Decision = outcome.Decision,
            Status = StatusFor(outcome),

            // The outcome's own failure first: an execution that failed terminally is described by that
            // failure, and the recording's is the one no outcome carries — a degraded tool loop.
            FailureCategory = outcome.Failure?.Category ?? recording.FailureCategory,
            ResultHash = ResultHashFor(request.Classification, outcome),
            ResultReference = null,
            Routing = outcome.Routing,
            Failover = outcome.Failover,
            At = _time.GetUtcNow(),
        });

        return outcome with { AuditReference = audit.ExecutionId };
    }

    /// <summary>
    /// The terminal status of an execution, read from what it produced.
    /// </summary>
    /// <remarks>
    /// <see cref="AiExecutionStatus.Blocked"/> and <see cref="AiExecutionStatus.Failed"/> are kept apart
    /// because they are different instructions to a caller: the first is a request to change, the second
    /// is a request to retry. A refusal that reached a provider and came back empty-handed is the second,
    /// which is why the test is on the failure and on whether anything was invoked rather than on whether
    /// a result happened to be present.
    /// </remarks>
    private static AiExecutionStatus StatusFor(GovernedTurnOutcome outcome)
    {
        if (outcome.Failure is not null && !outcome.Invoked)
        {
            return outcome.Decision.Verdict is AiGovernanceVerdict.HumanDecisionRequired
                ? AiExecutionStatus.PendingHumanDecision
                : AiExecutionStatus.Blocked;
        }

        if (outcome.Tools is { FinalResult.Success: false })
        {
            return AiExecutionStatus.Degraded;
        }

        if (outcome.Tools is { ProposedActions.Count: > 0 })
        {
            return AiExecutionStatus.PartiallySucceeded;
        }

        return outcome.Invoked && outcome.Result?.Result.Success is true
            ? AiExecutionStatus.Succeeded
            : AiExecutionStatus.Failed;
    }

    /// <summary>The digest of the result the caller received, or null where it must not be published.</summary>
    /// <remarks>
    /// Withheld for a <see cref="DataClassification.Secret"/> execution rather than hashed and then
    /// dropped by the emitter. <c>AiAuditEmitter</c> repeats the rule as its last act before the record
    /// becomes durable, and the repetition is the same deliberate redundancy as
    /// <c>AiContextDigest.Of</c>'s: hashing a secret extends its life, so the value should not be
    /// produced at all on the path where it is not wanted.
    /// </remarks>
    private static string? ResultHashFor(DataClassification classification, GovernedTurnOutcome outcome)
    {
        if (classification is DataClassification.Secret)
        {
            return null;
        }

        var content = (outcome.Tools?.FinalResult ?? outcome.Result?.Result)?.Message?.Content;

        return string.IsNullOrEmpty(content)
            ? null
            : Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(content)));
    }

    /// <summary>
    /// Resolves the turn's instruction set.
    /// </summary>
    /// <remarks>
    /// A turn that names no instruction set proceeds with an empty frame. That is not a hole: the
    /// governance engine evaluates its prompt gate only when an identifier is supplied, and an unstated
    /// instruction set is the state the live path has always been in for callers that set no agent. An
    /// identifier that <em>is</em> supplied must resolve — the engine re-checks approval and version at
    /// the invocation, so this resolution is about having a body to assemble rather than about
    /// permission, and an unregistered identifier is refused rather than quietly replaced by a built-in
    /// frame.
    /// </remarks>
    private bool TryResolveInstructionSet(
        string? promptId,
        out AiPromptRegistration? prompt,
        out string? failure)
    {
        prompt = null;
        failure = null;

        if (string.IsNullOrWhiteSpace(promptId))
        {
            return true;
        }

        if (!_prompts.TryGetPrompt(promptId, out var resolved) || resolved is null)
        {
            failure = $"Instruction set '{promptId}' is not in the prompt registry, so the turn has no frame "
                + "to assemble. An unregistered instruction set is refused rather than replaced with a "
                + "built-in one.";
            return false;
        }

        prompt = resolved;
        return true;
    }

    /// <summary>
    /// The classifications the caller declared for the supplied context.
    /// </summary>
    /// <remarks>
    /// Only the declared ones. An item whose classification is null is <em>undeclared</em>, and the
    /// builder treats it as the request's own classification — so substituting a value here would make
    /// the ceiling a statement about items nobody classified. The distinction is W7A's: the declared
    /// classification is the gate, the context ceiling is information.
    /// </remarks>
    private static IReadOnlyList<DataClassification> DeclaredClassifications(ContextBundle bundle)
        => bundle.Items
            .Select(item => item.Classification)
            .Where(classification => classification is not null)
            .Select(classification => classification!.Value)
            .ToArray();

    /// <summary>
    /// The caller's tool permission profile, derived from the tools the pipeline offered.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>The profile permits exactly the effects of the tools being offered, and no more.</b> A ceiling
    /// wider than the offer is a grant the caller never made; a narrower one refuses the offer's own
    /// tools. Deriving it means the profile and the offer cannot disagree, so the engine's ceiling check
    /// answers a question about the tools actually presented rather than about a number someone typed
    /// twice.
    /// </para>
    /// <para>
    /// <b><see cref="ToolPermissionProfile.RequireApprovalForWrites"/> is left at its default of
    /// true.</b> That is the load-bearing line for the advisory posture: an execution offering a
    /// side-effecting tool raises <see cref="AiGovernanceRules.ToolApprovalRequired"/>, which is a
    /// <see cref="AiGovernanceVerdict.HumanDecisionRequired"/> and therefore stops the invocation before
    /// any provider is called. A turn does not write on its own authority. It is carried forward as
    /// W7E CF-1 rather than made configurable here — see <c>W7E_CARRY_FORWARD.md</c>.
    /// </para>
    /// </remarks>
    private ToolPermissionProfile ProfileFor(GovernedTurnRequest request)
    {
        if (request.OfferedToolIds.Count == 0)
        {
            return ToolPermissionProfile.None;
        }

        var ceiling = ToolSideEffectClass.None;

        foreach (var toolId in request.OfferedToolIds)
        {
            var sideEffect = SideEffectFor(toolId);
            ceiling = sideEffect > ceiling ? sideEffect : ceiling;
        }

        return new ToolPermissionProfile
        {
            AllowedToolIds = request.OfferedToolIds,
            MaxSideEffect = ceiling,
            RequireApprovalForWrites = true,
            MaxToolCalls = MaxToolCalls,
        };
    }

    /// <summary>
    /// The AI registry's side-effect classification for a tool, or the most severe class when unknown.
    /// </summary>
    /// <remarks>
    /// An unknown tool is treated at <see cref="ToolSideEffectClass.Destructive"/> rather than skipped,
    /// which is the same inversion the governance engine applies: ignorance is the worst case, not the
    /// most permissive one. The engine will refuse the identifier outright as
    /// <see cref="AiGovernanceRules.ToolUnknown"/>; this only ensures the profile ceiling does not
    /// silently understate what was offered.
    /// </remarks>
    private ToolSideEffectClass SideEffectFor(string toolId)
        => _tools.TryGetTool(toolId, out var tool) && tool is not null
            ? tool.SideEffect
            : ToolSideEffectClass.Destructive;

    /// <summary>
    /// The verdict the tool loop enforces, drawn from the profile governance permitted.
    /// </summary>
    /// <remarks>
    /// The loop's own check is defence in depth and not the control. The control is that
    /// <see cref="GovernedTurnRequest.OfferedTools"/> was narrowed before the loop was entered: the loop
    /// can only call descriptors it was handed, and an identifier absent from that list is reported as
    /// skipped rather than resolved from anywhere else.
    /// </remarks>
    private static PolicyVerdict ToolVerdict(ToolPermissionProfile profile) => new()
    {
        Allowed = true,
        AllowedTools = profile.AllowedToolIds,
        RequireApprovalForWrites = profile.RequireApprovalForWrites,
    };

    /// <summary>A rough input size for the router's context-fit gate. Zero means no estimate was stated.</summary>
    /// <remarks>
    /// A character count over four, the same ratio <c>PromptAssembler</c> uses. It is an estimate and is
    /// treated as one — the router refuses only when a stated size exceeds a stated limit, so an estimate
    /// that is slightly wrong changes which route fits, not whether a limit is enforced.
    /// </remarks>
    private static int EstimateInputTokens(GovernedTurnRequest request)
    {
        var characters = request.Input.Text.Length;

        foreach (var item in request.Context.Items)
        {
            characters += item.Body.Length;
        }

        return characters / 4;
    }

    private static DecisionTrace RoutingTrace(AiRoutingOutcome routing) => routing.IsRouted
        ? new DecisionTrace(
            $"Routed the turn to '{routing.Selected!.ModelId}' on provider '{routing.Selected.ProviderId}'",
            $"Chosen from {routing.Eligible.Count} permitted route(s); {routing.Rejected.Count} were refused.",
            [.. routing.Rejected.Select(rejection => $"{rejection.ModelId}:{rejection.Reason}")])
        : new DecisionTrace(
            $"Refused to route the turn: {routing.Status}",
            routing.Reason ?? "No route was selected.",
            [.. routing.Rejected.Select(rejection => $"{rejection.ModelId}:{rejection.Reason}")]);

    private static GovernedTurnOutcome Refused(
        string executionId,
        AiGovernanceDecision decision,
        string correlationId,
        IReadOnlyList<DecisionTrace> decisions) => new()
        {
            ExecutionId = executionId,
            Decision = decision,
            Invoked = false,
            Failure = decision.ToFailure(correlationId),
            Decisions = decisions,
        };

    /// <summary>One route, plus the governance question asked about it and its place in the sequence.</summary>
    private sealed record ActiveRoute(
        AiRoutingCandidate Candidate,
        AiGovernanceEvaluationRequest GovernanceRequest,
        int Order,
        bool IsFallback,
        AiOperationalVerdict? Operational = null);

    /// <summary>What one attempt did, and what it cost.</summary>
    private sealed record RouteOutcome(
        AiGovernanceDecision Decision,
        bool Invoked,
        ModelStepResult? Result,
        AiFailure? Failure,
        AiUsageEntry? Entry,
        TimeSpan? Latency,
        DateTimeOffset At);

    /// <summary>
    /// What an execution accumulated across its attempts, in the order they happened.
    /// </summary>
    /// <remarks>
    /// <b>Mutable, and confined to one execution.</b> The stage sequence learns a fact at five different
    /// points and the records are written once at the end; threading five return values back to one place
    /// would be five chances to drop one. Nothing else holds a reference to an instance of this type.
    /// </remarks>
    private sealed class ExecutionRecording
    {
        private readonly List<string> _tools = [];
        private int _attempts;

        /// <summary>
        /// The AI Head's identity for this execution, minted once by <see cref="ExecuteAsync"/>.
        /// </summary>
        /// <remarks>
        /// Held here rather than passed down the stage sequence because every record written at the end
        /// of it — the usage entry, the execution evidence and the audit record — is keyed by it, and a
        /// value passed through six methods to reach three writers is a value one of them eventually
        /// forgets to pass.
        /// </remarks>
        public required string ExecutionId { get; init; }

        /// <summary>When the execution began, for the total latency.</summary>
        public required long StartTimestamp { get; init; }

        /// <summary>The tier the routing decision was taken under.</summary>
        public AiProcessingTier Tier { get; set; } = AiProcessingTier.Standard;

        /// <summary>The admitted context, as references and digests. Never the content.</summary>
        public IReadOnlyList<AiContextReference> ContextReferences { get; set; } = [];

        /// <summary>The instruction set version applied, where one was.</summary>
        public string? PromptVersion { get; set; }

        /// <summary>The provider that last produced a result.</summary>
        public string? ProviderUsed { get; private set; }

        /// <summary>The model that last produced a result.</summary>
        public string? ModelUsed { get; private set; }

        /// <summary>The category of a failure no outcome carries — a degraded tool loop.</summary>
        public AiFailureCategory? FailureCategory { get; set; }

        /// <summary>
        /// Input tokens across every invocation of this execution, or <c>null</c> when any invocation
        /// reported no usage.
        /// </summary>
        /// <remarks>
        /// <b>A sum with an unknown part is unknown.</b> Once one attempt's usage is unreported the
        /// execution has no token total, and reporting the sum of the attempts that did report would be
        /// a number that looks complete and is not.
        /// </remarks>
        public int? TokensIn { get; private set; } = 0;

        /// <summary>Output tokens across every invocation of this execution, or <c>null</c> when any did not report.</summary>
        /// <remarks>See <see cref="TokensIn"/>.</remarks>
        public int? TokensOut { get; private set; } = 0;

        /// <summary>The execution's cost, accumulated across its invocations.</summary>
        public ExecutionCost Cost { get; private set; } = ExecutionCost.Empty;

        /// <summary>The tools the execution invoked, by identifier.</summary>
        public IReadOnlyList<string> ToolsInvoked => _tools;

        /// <summary>Takes what one attempt consumed and what it served.</summary>
        /// <remarks>
        /// A refused attempt is absorbed as a no-op rather than as a zero. The two are different: a
        /// recorded zero would say the estate spent nothing on a route it never used, and would make the
        /// model and provider of a refused route the ones the audit record names as having served the
        /// request.
        /// </remarks>
        public void Absorb(ActiveRoute route, RouteOutcome call)
        {
            if (!call.Invoked)
            {
                return;
            }

            // Last one wins, so a request served by a fallback names the fallback rather than the primary
            // it abandoned.
            ProviderUsed = route.Candidate.ProviderId;
            ModelUsed = route.Candidate.ModelId;

            if (call.Entry is { } entry)
            {
                // Absence poisons the total rather than contributing zero: see TokensIn.
                TokensIn = TokensIn is { } runningIn && entry.TokensIn is { } attemptIn
                    ? runningIn + attemptIn
                    : null;
                TokensOut = TokensOut is { } runningOut && entry.TokensOut is { } attemptOut
                    ? runningOut + attemptOut
                    : null;
                Cost = Cost.Add(entry);
            }
        }

        /// <summary>Notes the tools the tool loop invoked.</summary>
        public void NoteTools(IReadOnlyList<string> toolIds) => _tools.AddRange(toolIds);

        /// <summary>
        /// The identity of the next provider-call attempt, unique within this execution.
        /// </summary>
        /// <remarks>
        /// <para>
        /// <b>Composed from the execution identity rather than minted independently.</b> An ordinal on
        /// its own would repeat across executions, and the ledger is read across executions: two
        /// fallback attempts in two different turns would both be "…:2" and neither would be resolvable
        /// on its own. Prefixing the execution identity makes the attempt identity globally unique
        /// without a second source, and makes it self-describing — an operator holding one can see which
        /// execution it belongs to without a lookup.
        /// </para>
        /// <para>
        /// <b>The counter advances only where an entry is written.</b> <see cref="InvokeAsync"/> takes
        /// the identity after the invocation gate has permitted the call, so the ordinals for one
        /// execution run one-through-N with no gaps and "attempt two" means the second call the
        /// execution actually made. A refused round is evidence the execution records per route, not
        /// spend, and the ledger is the spend surface.
        /// </para>
        /// </remarks>
        public string NextAttemptId() => $"{ExecutionId}:{++_attempts}";
    }

    /// <summary>
    /// An execution's cost, built from the entries its invocations wrote.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Two figures are accumulated separately and neither overwrites the other.</b> That is what makes
    /// <see cref="AiCostBasis"/> mean something at the execution level: the estimate is what every budget
    /// decision rested on and the measurement is what the providers reported, and an execution whose
    /// basis is <see cref="AiCostBasis.Estimated"/> is one where nothing measured the spend.
    /// </para>
    /// <para>
    /// <b>An unpriced attempt contributes nothing rather than erasing a priced sibling.</b> The total is
    /// what the estate spent on the attempts it can price, and the ledger still holds one entry per
    /// invocation with that invocation's own basis — so a reader who needs to know which attempt was
    /// unpriced asks the ledger rather than inferring it from a sum.
    /// </para>
    /// </remarks>
    private sealed record ExecutionCost(decimal? Estimated, decimal? Actual, string? Currency, bool Mixed)
    {
        /// <summary>Nothing recorded yet.</summary>
        public static ExecutionCost Empty { get; } = new(null, null, null, false);

        /// <summary>Which figure a reader should use, and why.</summary>
        public AiCostBasis Basis => Mixed ? AiCostBasis.Unpriced : AiCostReconciler.BasisFor(Estimated, Actual);

        /// <summary>The amount to publish, or null when no single figure can be stated.</summary>
        public decimal? Amount => Mixed ? null : AiCostReconciler.Authoritative(Estimated, Actual);

        /// <summary>The currency of <see cref="Amount"/>, or null when none can be stated.</summary>
        public string? AmountCurrency => Mixed ? null : Currency;

        /// <summary>Folds one invocation's entry into the running total.</summary>
        public ExecutionCost Add(AiUsageEntry entry)
        {
            var mixed = Mixed
                || (Currency is { Length: > 0 } held
                    && entry.Currency is { Length: > 0 } incoming
                    && !string.Equals(held, incoming, StringComparison.Ordinal));

            return new ExecutionCost(
                Sum(Estimated, entry.EstimatedCost),
                Sum(Actual, entry.ActualCost),

                // Once two currencies have been seen the total is unstateable, so the currency stays
                // unset rather than being taken from whichever attempt happened to be last.
                mixed ? null : Currency ?? entry.Currency,
                mixed);
        }

        private static decimal? Sum(decimal? accumulated, decimal? added)
            => accumulated is null && added is null ? null : (accumulated ?? 0m) + (added ?? 0m);
    }
}
