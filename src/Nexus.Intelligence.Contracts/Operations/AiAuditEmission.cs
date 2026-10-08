namespace Nexus.Intelligence.Contracts;

/// <summary>
/// Everything the emitter needs to build one audit record.
/// </summary>
/// <remarks>
/// <para>
/// <b>A context type rather than a long parameter list, because every field is optional in some
/// path.</b> A refused execution has no provider, no usage and no result; a routed one that failed
/// inside the provider has a provider and no usage. An emitter taking twenty positional arguments
/// would have to accept nulls in twenty places and would eventually be called with two of them
/// swapped.
/// </para>
/// <para>
/// <b>Nothing here can hold a credential, and that is structural.</b> Every member is a typed
/// contract value or an identifier; there is no free-form field for a provider payload, a request
/// header, an endpoint or a key. The one place an operator's free text enters is
/// <see cref="AiAuditRecord.Purpose"/>, which the record's own <c>Sanitized</c> method routes
/// through <see cref="AiRedaction"/>.
/// </para>
/// </remarks>
public sealed record AiAuditEmissionContext
{
    /// <summary>The AI Head's identifier for this execution.</summary>
    public required string ExecutionId { get; init; }

    /// <summary>The caller's request identifier.</summary>
    public required string RequestId { get; init; }

    /// <summary>Correlates across services.</summary>
    public required string CorrelationId { get; init; }

    /// <summary>Who asked, and within what scope.</summary>
    public required AiRequesterIdentity Requester { get; init; }

    /// <summary>What was asked for.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>Why the caller said it was asking.</summary>
    public required string Purpose { get; init; }

    /// <summary>How the request was classified.</summary>
    public required DataClassification Classification { get; init; }

    /// <summary>When the execution completed.</summary>
    public required DateTimeOffset Timestamp { get; init; }

    /// <summary>References to the context supplied. Never the context itself.</summary>
    public IReadOnlyList<AiContextReference> ContextReferences { get; init; } = [];

    /// <summary>Which provider served it, where one did.</summary>
    public string? ProviderUsed { get; init; }

    /// <summary>Which model served it, where one did.</summary>
    public string? ModelUsed { get; init; }

    /// <summary>The prompt or instruction set version applied.</summary>
    public string? PromptVersion { get; init; }

    /// <summary>Tools the execution invoked, by identifier.</summary>
    public IReadOnlyList<string> ToolsInvoked { get; init; } = [];

    /// <summary>Tokens and units consumed.</summary>
    public AiTokenUsage Usage { get; init; } = AiTokenUsage.None;

    /// <summary>What it cost, where a price was available.</summary>
    public AiCost? Cost { get; init; }

    /// <summary>How long it took.</summary>
    public AiTiming? Timing { get; init; }

    /// <summary>What policy decided.</summary>
    public AiPolicyDecision? PolicyDecision { get; init; }

    /// <summary>What evaluation concluded, where evaluation ran.</summary>
    public AiEvaluationResult Evaluation { get; init; } = AiEvaluationResult.NotEvaluated;

    /// <summary>The terminal status.</summary>
    public required AiExecutionStatus Status { get; init; }

    /// <summary>The failure category, when the execution did not succeed.</summary>
    public AiFailureCategory? FailureCategory { get; init; }

    /// <summary>A digest of the result, where one was produced.</summary>
    public string? ResultHash { get; init; }

    /// <summary>A resolvable reference to the stored result, under authority.</summary>
    public string? ResultReference { get; init; }
}

/// <summary>
/// Where audit records go.
/// </summary>
/// <remarks>
/// <para>
/// <b>The write is the only operation, and there is no read.</b> Reading audit evidence is a
/// different act with a different authorization story, and a port that offered both would make the
/// read as available as the write. A later lane that needs the read defines it, with the authority
/// question answered.
/// </para>
/// <para>
/// <b>Synchronous, because the emitter runs on the execution path after the provider call.</b>
/// Making it asynchronous would invite an implementation to buffer, and a buffered audit trail is
/// one that is missing exactly the records for the executions that crashed.
/// </para>
/// </remarks>
public interface IAiAuditSink
{
    /// <summary>Writes one audit record.</summary>
    void Write(AiAuditRecord record);

    /// <summary>How many records have been written. An operational counter, not an audit read.</summary>
    int Count { get; }
}

/// <summary>
/// Where audit records are read back from.
/// </summary>
/// <remarks>
/// <para>
/// <b>A separate port from <see cref="IAiAuditSink"/>, and separate on purpose.</b> Writing audit
/// evidence and reading it are different acts with different authorization stories: every execution
/// writes one, and only an operator under authority reads them. One port offering both would make the
/// read exactly as available as the write, which is how an audit trail becomes an ordinary data
/// source.
/// </para>
/// <para>
/// It exists because W7E TASK 9 asks for an operational read surface, and a read surface that
/// re-derived governance outcomes instead of reading the evidence would be a second source of truth
/// for what governance decided.
/// </para>
/// </remarks>
public interface IAiAuditReader
{
    /// <summary>The record for one execution, or null when nothing was written for it.</summary>
    AiAuditRecord? Find(string executionId);

    /// <summary>Records for a set of executions, in the order asked for; absent ones are skipped.</summary>
    IReadOnlyList<AiAuditRecord> FindMany(IEnumerable<string> executionIds);

    /// <summary>Every record written, most recent first, bounded by <paramref name="max"/>.</summary>
    IReadOnlyList<AiAuditRecord> Recent(int max);

    /// <summary>How many records have been written.</summary>
    int Count { get; }
}

/// <summary>
/// The routing, operational and failover evidence for one execution.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is what the audit record does not carry, and nothing that it does.</b> The audit record is
/// the governance evidence and its shape is fixed by W7D: what was asked, what governed it, what
/// served it, what it cost. It has no field for the router's rejection list, for the operational
/// gates' findings, or for which fallback candidates were skipped and why — and adding those to it
/// would turn a ledger into a payload, which is precisely what its own remarks say it must not
/// become.
/// </para>
/// <para>
/// Every fact here is therefore recorded exactly once, in exactly one place: governance outcome in
/// the audit record, consumption in the usage ledger, routing and failover evidence here. The
/// operations read model joins them; none of them is derived from another.
/// </para>
/// </remarks>
public sealed record AiExecutionEvidence
{
    /// <summary>The AI Head's identifier for this execution.</summary>
    public required string ExecutionId { get; init; }

    /// <summary>The caller's request identifier.</summary>
    public required string RequestId { get; init; }

    /// <summary>The capability that was requested.</summary>
    public required CapabilityId Capability { get; init; }

    /// <summary>The processing tier the work ran under.</summary>
    public AiProcessingTier Tier { get; init; } = AiProcessingTier.Standard;

    /// <summary>How many routes the router found eligible.</summary>
    public int EligibleRoutes { get; init; }

    /// <summary>Every route the router refused, with the gate that refused it.</summary>
    public IReadOnlyList<AiRoutingRejection> RoutingRejections { get; init; } = [];

    /// <summary>Every operational gate finding across every candidate.</summary>
    public IReadOnlyList<AiOperationalRejection> OperationalFindings { get; init; } = [];

    /// <summary>The operational budget verdict for the route that was chosen, where the gate ran.</summary>
    public AiBudgetDecision? Budget { get; init; }

    /// <summary>
    /// The priced-route-to-unpriced-route substitution a failover made, where it made one.
    /// </summary>
    /// <remarks>
    /// <b>W7F TASK 5.</b> Recorded on the execution's routing and operational evidence rather than on
    /// the audit record, because that is the record whose subject it is: the audit record is the
    /// governance evidence and its shape is W7D's, while the fact that the priced route did not serve
    /// is a routing fact. It is written here, once, beside the budget verdict it qualifies — so the
    /// two are read together and a reader cannot take the verdict without the substitution.
    /// </remarks>
    public AiBudgetSubstitution? BudgetSubstitution { get; init; }

    /// <summary>The reliability evidence read for the route that was chosen, where the gate ran.</summary>
    public AiReliabilityEvidence? Reliability { get; init; }

    /// <summary>
    /// The circuit state the recovery gate read for the route that was chosen, where the model applied.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Recorded beside <see cref="Reliability"/> because the two are read together: the reliability
    /// evidence says what the route's record was, and this says what the estate decided to do about it.
    /// An execution that served on probation and one that served as ordinary capacity have identical
    /// reliability evidence and different circuit states, and an audit that published only the first
    /// could not tell them apart.
    /// </para>
    /// <para>
    /// A route refused <em>by</em> its circuit does not appear here, because nothing was selected. Its
    /// circuit state is on the rejection in <see cref="OperationalFindings"/>, which is where the
    /// evidence of a decision not to run belongs.
    /// </para>
    /// </remarks>
    public AiCircuitSnapshot? Circuit { get; init; }

    /// <summary>
    /// Whether the chosen route served on probation rather than as ordinary capacity.
    /// </summary>
    /// <remarks>
    /// The single fact that distinguishes a call the estate spent deliberately to test a recovering
    /// route from a call it spent as a matter of course. Without it, a probationary probe is
    /// indistinguishable in the audit from ordinary traffic — and the bound on probe traffic, which is
    /// the reason the model is safe, would be a bound nothing recorded.
    /// </remarks>
    public bool IsProbe { get; init; }

    /// <summary>The model's health as routing saw it, where a route was selected.</summary>
    public AiModelHealthState? ModelHealth { get; init; }

    /// <summary>The provider's health as routing saw it, where a route was selected.</summary>
    public AiModelHealthState? ProviderHealth { get; init; }

    /// <summary>The failover record, where the operational plane ran.</summary>
    public AiFailoverDecision? Failover { get; init; }

    /// <summary>When the evidence was written.</summary>
    public required DateTimeOffset RecordedAt { get; init; }
}

/// <summary>
/// Where per-execution routing and operational evidence is written and read.
/// </summary>
/// <remarks>
/// <b>One write per execution, from the governed path, whether or not anything was refused.</b> An
/// execution with no refusals still has evidence — the eligible route count, the operational findings
/// about the route that was chosen, and the failover record saying no failover was needed — and a
/// store that only recorded refusals would make a quiet estate indistinguishable from an
/// unobserved one.
/// </remarks>
public interface IAiExecutionEvidenceStore
{
    /// <summary>Writes one execution's evidence.</summary>
    void Write(AiExecutionEvidence evidence);

    /// <summary>The evidence for one execution, or null when nothing was written for it.</summary>
    AiExecutionEvidence? Find(string executionId);

    /// <summary>Every execution identifier evidence was written for, most recent first.</summary>
    IReadOnlyList<string> RecentExecutionIds(int max);

    /// <summary>How many evidence records have been written.</summary>
    int Count { get; }
}

/// <summary>
/// Builds and writes the audit record for a governed execution.
/// </summary>
/// <remarks>
/// <para>
/// <b>One record per execution, written for every outcome including refusals.</b> Before this type
/// the record existed, had a serializer and a redactor, and was never constructed — so the estate
/// had an audit vocabulary and no audit trail, which is worse than having neither because the
/// vocabulary is what a reviewer checks for.
/// </para>
/// <para>
/// <b>It writes through <see cref="AiAuditRecord.Sanitized"/>.</b> The record's own fields are typed
/// and cannot hold a credential; the fields a human writes are redacted on the way out. Direct
/// serialization is not offered.
/// </para>
/// </remarks>
public interface IAiAuditEmitter
{
    /// <summary>Builds the record for an execution, without writing it.</summary>
    AiAuditRecord Build(AiAuditEmissionContext context);

    /// <summary>Builds the record for an execution and writes it to the sink.</summary>
    AiAuditRecord Emit(AiAuditEmissionContext context);
}
