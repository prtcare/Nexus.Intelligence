namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The stable identifiers of the rules AI Governance can apply.
/// </summary>
/// <remarks>
/// <para>
/// <b>These are the registry, and they are constants only because they must be stable across
/// deployments.</b> The directive's "prefer registries and policy records over hardcoded provider and
/// model lists" is not satisfied by moving every string into a class — it is satisfied by making sure
/// no <em>membership</em> decision lives in code. A rule identifier is not membership: it names a
/// check the engine performs, and a check that could be renamed by configuration would make an audit
/// record unable to say which rule fired. What the policy records supply instead is which models,
/// providers, agents, prompts, tools and budgets those rules are applied <em>to</em>, and that is
/// where every list lives.
/// </para>
/// <para>
/// Each identifier is validated against the shared stable-identifier format
/// (<see cref="CapabilityId.TryParse"/>) when a policy record carries one, so a malformed rule
/// identifier fails at composition rather than appearing in an audit record.
/// </para>
/// </remarks>
public static class AiGovernanceRules
{
    // --- Prohibition and authority -----------------------------------------------------------------
    // Evaluated first, and decisive when they fire. These are the rules that keep AI out of surfaces
    // a deterministic authority owns.

    /// <summary>No rule refused. The deciding rule of an allowed execution.</summary>
    /// <remarks>
    /// A named rule rather than an empty identifier, because an allowed execution is still a governed
    /// execution and its audit record must be able to say which check concluded it. "No rule fired" is
    /// a fact worth recording; an absent value would be indistinguishable from a record that was never
    /// written.
    /// </remarks>
    public const string Allowed = "governance.allowed";

    /// <summary>The request touches a protected surface on which AI participation is forbidden.</summary>
    public const string ProhibitedSurface = "governance.prohibited.surface";

    /// <summary>The capability is prohibited outright by the dependency register.</summary>
    public const string ProhibitedCapability = "governance.prohibited.capability";

    /// <summary>The platform's deterministic governance refused the action this execution belongs to.</summary>
    public const string PlatformAuthorityRefused = "governance.platform.refused";

    /// <summary>The platform authenticated the action it governs, and is recorded for the audit trail.</summary>
    public const string PlatformAuthorityAttested = "governance.platform.attested";

    // --- Capability --------------------------------------------------------------------------------

    /// <summary>The capability is not registered, or is registered and disabled.</summary>
    public const string CapabilityNotServable = "governance.capability.not-servable";

    /// <summary>The capability's declared dependency class is AI-prohibited.</summary>
    public const string CapabilityDependencyProhibited = "governance.capability.prohibited";

    // --- Models and providers ----------------------------------------------------------------------

    /// <summary>The selected model is not present in the governance register.</summary>
    public const string ModelUnregistered = "governance.model.unregistered";

    /// <summary>The selected model is registered but not approved for use.</summary>
    public const string ModelNotApproved = "governance.model.not-approved";

    /// <summary>The selected provider is not present in the governance register.</summary>
    public const string ProviderUnregistered = "governance.provider.unregistered";

    /// <summary>The selected provider is registered but not approved for use.</summary>
    public const string ProviderNotApproved = "governance.provider.not-approved";

    /// <summary>The content's classification exceeds what the selected model is cleared to receive.</summary>
    public const string ModelClassificationCeiling = "governance.model.classification-ceiling";

    /// <summary>The content's classification exceeds what the selected provider is cleared to receive.</summary>
    /// <remarks>
    /// Separate from <see cref="ModelClassificationCeiling"/> rather than shared, because the two
    /// clearances are granted independently: a provider assessed for one classification can be serving a
    /// model assessed for another, and a single identifier would leave an audit record unable to say which
    /// of the two ceilings the execution hit.
    /// </remarks>
    public const string ProviderClassificationCeiling = "governance.provider.classification-ceiling";

    // --- Agents ------------------------------------------------------------------------------------

    /// <summary>The selected agent is not present in the governance register.</summary>
    public const string AgentUnregistered = "governance.agent.unregistered";

    /// <summary>The selected agent is registered but not approved for use.</summary>
    public const string AgentNotApproved = "governance.agent.not-approved";

    /// <summary>The selected agent is not approved for the requested capability.</summary>
    public const string AgentCapabilityNotPermitted = "governance.agent.capability-not-permitted";

    // --- Prompts and instructions --------------------------------------------------------------------

    /// <summary>The prompt or instruction set is not present in the governance register.</summary>
    public const string PromptUnregistered = "governance.prompt.unregistered";

    /// <summary>The prompt or instruction set is registered but not approved for use.</summary>
    public const string PromptNotApproved = "governance.prompt.not-approved";

    /// <summary>The prompt carries no version, so an execution using it cannot be reproduced.</summary>
    public const string PromptUnversioned = "governance.prompt.unversioned";

    // --- Data exposure and context ------------------------------------------------------------------

    /// <summary>The declared classification may not reach the requested destination.</summary>
    public const string ExposureBlocked = "governance.exposure.blocked";

    /// <summary>Context was drawn from a scope the requester did not declare.</summary>
    public const string ContextScopeUndeclared = "governance.context.scope-undeclared";

    // --- Security -----------------------------------------------------------------------------------

    /// <summary>The selected provider's trust tier is below the floor remote egress requires.</summary>
    public const string SecurityTrustBelowFloor = "governance.security.trust-below-floor";

    /// <summary>The selected provider or model is not permitted to receive content over the network.</summary>
    public const string SecurityEgressNotPermitted = "governance.security.egress-not-permitted";

    // --- Tools --------------------------------------------------------------------------------------

    /// <summary>The requested tool identifier is not in the caller's tool permission profile.</summary>
    public const string ToolNotPermitted = "governance.tool.not-permitted";

    /// <summary>The requested tool is not in the governance tool register, so its effect is unknown.</summary>
    public const string ToolUnknown = "governance.tool.unknown";

    /// <summary>The tool's side-effect class exceeds the profile ceiling.</summary>
    public const string ToolSideEffectExceeded = "governance.tool.side-effect-exceeded";

    /// <summary>The tool causes a side effect and a human must approve the call.</summary>
    public const string ToolApprovalRequired = "governance.tool.approval-required";

    /// <summary>More tool calls were requested than the profile permits.</summary>
    public const string ToolCallCeilingExceeded = "governance.tool.call-ceiling-exceeded";

    // --- Cost and budget ----------------------------------------------------------------------------

    /// <summary>The estimated cost exceeds a budget rule's ceiling. Deterministic for the same inputs.</summary>
    public const string BudgetExceeded = "governance.budget.exceeded";

    /// <summary>A priced execution has no budget rule covering it, so no ceiling can be enforced.</summary>
    public const string BudgetUncovered = "governance.budget.uncovered";

    // --- Evaluation and output risk -------------------------------------------------------------------

    /// <summary>The caller's quality requirement cannot be evidenced for this execution.</summary>
    public const string EvaluationQualityUnevidenced = "governance.evaluation.quality-unevidenced";

    // --- Human-decision escalation ---------------------------------------------------------------------

    /// <summary>A declared escalation rule matched, so a human must decide.</summary>
    public const string EscalationDeclared = "governance.escalation.declared";

    /// <summary>Every rule identifier this engine defines, ordered for a deterministic listing.</summary>
    public static IReadOnlyList<string> All { get; } =
    [
        Allowed,
        ProhibitedSurface,
        ProhibitedCapability,
        PlatformAuthorityRefused,
        PlatformAuthorityAttested,
        CapabilityNotServable,
        CapabilityDependencyProhibited,
        ModelUnregistered,
        ModelNotApproved,
        ProviderUnregistered,
        ProviderNotApproved,
        ModelClassificationCeiling,
        ProviderClassificationCeiling,
        AgentUnregistered,
        AgentNotApproved,
        AgentCapabilityNotPermitted,
        PromptUnregistered,
        PromptNotApproved,
        PromptUnversioned,
        ExposureBlocked,
        ContextScopeUndeclared,
        SecurityTrustBelowFloor,
        SecurityEgressNotPermitted,
        ToolNotPermitted,
        ToolUnknown,
        ToolSideEffectExceeded,
        ToolApprovalRequired,
        ToolCallCeilingExceeded,
        BudgetExceeded,
        BudgetUncovered,
        EvaluationQualityUnevidenced,
        EscalationDeclared,
    ];

    /// <summary>True when an identifier is one this engine defines and is well-formed.</summary>
    public static bool IsKnown(string? ruleId)
        => ruleId is not null
           && CapabilityId.IsValid(ruleId)
           && All.Contains(ruleId, StringComparer.Ordinal);
}

/// <summary>
/// What AI Governance decided about one proposed execution.
/// </summary>
/// <remarks>
/// <para>
/// <b><see cref="Combine"/> is the only operator that composes two decisions</b>, and it is
/// most-restrictive: the winning verdict is the highest by severity, so no sequence of combinations
/// can lower a verdict. That is the mechanism behind the directive's requirement that a
/// human-required decision cannot silently become <c>ALLOW</c> — there is no method on this type that
/// weakens one, and adding one would be a visible change to the type rather than an edit to a caller.
/// </para>
/// <para>
/// <see cref="RuleId"/> names the <em>deciding</em> rule; <see cref="RulesApplied"/> records everything
/// that fired, in evaluation order, across all the namespaces involved — read that member's remarks
/// before consuming it, because it is a trace and not a list of <see cref="AiGovernanceRules"/> members.
/// Both are recorded, because the deciding rule answers "why was this refused" and the applied set
/// answers "what else is true about this request" — a reviewer auditing a block needs the first, and a
/// reviewer auditing a <em>change</em> to the policy needs the second.
/// </para>
/// </remarks>
public sealed record AiGovernanceDecision
{
    /// <summary>The verdict.</summary>
    public required AiGovernanceVerdict Verdict { get; init; }

    /// <summary>
    /// The rule that produced <see cref="Verdict"/>, or <see cref="AiGovernanceRules.Allowed"/> when
    /// nothing refused the execution.
    /// </summary>
    /// <remarks>
    /// The deciding rule and not the most severe rule considered: on a refusal this is the rule that
    /// produced the refusal, and every other rule that also fired is in <see cref="RulesApplied"/>. It is
    /// always a member of <see cref="AiGovernanceRules"/>.
    /// </remarks>
    public required string RuleId { get; init; }

    /// <summary>A caller-safe explanation. Never a provider error body, never a credential, never a prompt.</summary>
    public required string Reason { get; init; }

    /// <summary>Everything that fired, in evaluation order, across several namespaces.</summary>
    /// <remarks>
    /// <para>
    /// <b>This is a trace, not a list of <see cref="AiGovernanceRules"/> members, and consuming code must
    /// not assume otherwise.</b> Five kinds of entry appear here. They are listed because a consumer that
    /// assumed one kind would silently misread the others — which is exactly what an earlier draft of this
    /// member's own documentation did:
    /// </para>
    /// <list type="number">
    /// <item><description>
    /// Members of <see cref="AiGovernanceRules"/> (<c>governance.*</c>) — the rules of this contract, always
    /// <c>CapabilityId</c>-shaped, and the only entries <see cref="AiGovernanceRules.IsKnown"/> accepts.
    /// </description></item>
    /// <item><description>
    /// A platform authority identifier (<c>platform.*</c>), recording which authority attested — or
    /// <see cref="AiGovernanceAuthority.None"/> when no platform action was attached, which says the
    /// execution was attached to nothing rather than that something permitted it.
    /// </description></item>
    /// <item><description>
    /// The <c>RuleId</c> of a policy record that fired: a budget, tool or escalation rule. These are
    /// supplied by configuration, so their values are not known to this contract — but they are
    /// <c>CapabilityId</c>-shaped, because the policy validates them at composition.
    /// </description></item>
    /// <item><description>
    /// An enum member name, recording which value of a closed set the decision turned on — the prohibited
    /// surface, or an approval status such as <c>Suspended</c>. Not an identifier, and not shaped like one.
    /// </description></item>
    /// <item><description>
    /// The data-exposure table's own trace of the row it applied and the context ceiling it computed, in
    /// that engine's format.
    /// </description></item>
    /// </list>
    /// <para>
    /// <b>How to consume it.</b> To ask whether one specific rule fired, test for that identifier. To
    /// enumerate the governance rules that fired, intersect with <see cref="AiGovernanceRules.All"/> — a
    /// raw scan over this list will also read entries of kinds 2 to 5 as rules. To display the record to a
    /// person, print it as it stands; it is ordered, de-duplicated and human-readable by design.
    /// </para>
    /// <para>
    /// <b>Why one list rather than five.</b> A reviewer reading an audit record wants the whole story in
    /// the order it happened. Splitting it by namespace would make the record accurate and unreadable, and
    /// the fields a program needs to branch on are already typed: <see cref="Verdict"/>,
    /// <see cref="RuleId"/> and <see cref="FailureCategory"/>.
    /// </para>
    /// </remarks>
    public IReadOnlyList<string> RulesApplied { get; init; } = [];

    /// <summary>
    /// The typed failure category for the caller, present exactly when <see cref="Verdict"/> is a refusal.
    /// </summary>
    public AiFailureCategory? FailureCategory { get; init; }

    /// <summary>True when the execution may proceed.</summary>
    public bool IsAllowed => Verdict is AiGovernanceVerdict.Allow;

    /// <summary>True when a named human must decide before the execution may proceed.</summary>
    public bool RequiresHumanDecision => Verdict is AiGovernanceVerdict.HumanDecisionRequired;

    /// <summary>True when AI participation is refused and no human may lift it at this gate.</summary>
    public bool IsBlocked => Verdict is AiGovernanceVerdict.Block;

    /// <summary>An allowing decision.</summary>
    public static AiGovernanceDecision Allow(params string[] rules) => new()
    {
        Verdict = AiGovernanceVerdict.Allow,
        RuleId = AiGovernanceRules.Allowed,
        Reason = "No AI governance rule refused this execution.",
        RulesApplied = rules ?? [],
    };

    /// <summary>A blocking decision.</summary>
    public static AiGovernanceDecision Block(
        string ruleId,
        string reason,
        AiFailureCategory failureCategory,
        params string[] rules) => new()
    {
        Verdict = AiGovernanceVerdict.Block,
        RuleId = ruleId,
        Reason = reason,
        FailureCategory = failureCategory,
        RulesApplied = rules is { Length: > 0 } ? rules : [ruleId],
    };

    /// <summary>A decision that a named human must take.</summary>
    /// <remarks>
    /// The failure category is fixed to <see cref="AiFailureCategory.HumanDecisionRequired"/>, which
    /// <see cref="AiFailure.From"/> already marks non-retryable and requiring human action. It is not a
    /// parameter because a human-required decision reported under any other category — a timeout, say —
    /// is a decision that gets retried until it silently becomes an answer.
    /// </remarks>
    public static AiGovernanceDecision HumanDecisionRequired(string ruleId, string reason, params string[] rules) => new()
    {
        Verdict = AiGovernanceVerdict.HumanDecisionRequired,
        RuleId = ruleId,
        Reason = reason,
        FailureCategory = AiFailureCategory.HumanDecisionRequired,
        RulesApplied = rules is { Length: > 0 } ? rules : [ruleId],
    };

    /// <summary>
    /// Composes two decisions, keeping the most restrictive verdict.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The rule list is the union, ordered and de-duplicated, so the result is a property of the set of
    /// decisions rather than of the order they were combined in. The deciding rule is the first rule
    /// recorded at the winning severity, which makes a decision reproducible from its inputs.
    /// </para>
    /// <para>
    /// <b>There is deliberately no method that relaxes a decision.</b> A caller that needs a weaker
    /// verdict must obtain one from the evaluator, which means changing the policy the evaluator reads
    /// — a governance act with a record — rather than post-processing a refusal into a permission.
    /// </para>
    /// </remarks>
    public AiGovernanceDecision Combine(AiGovernanceDecision other)
    {
        ArgumentNullException.ThrowIfNull(other);

        var verdict = Verdict.MostRestrictive(other.Verdict);
        var rules = RulesApplied.Concat(other.RulesApplied).Distinct(StringComparer.Ordinal).ToArray();

        if (verdict == Verdict)
        {
            return this with { RulesApplied = rules };
        }

        return other with { RulesApplied = rules };
    }

    /// <summary>The typed failure for a refusal, or <see langword="null"/> when the execution may proceed.</summary>
    /// <remarks>
    /// An allowed decision produces no failure, and that is asserted rather than assumed: a caller that
    /// receives a failure for an allowed decision has no rule to remedy it against, and would treat the
    /// failure as unrelated noise.
    /// </remarks>
    public AiFailure? ToFailure(string correlationId)
    {
        if (IsAllowed)
        {
            return null;
        }

        return AiFailure.From(
            FailureCategory ?? AiFailureCategory.PolicyBlocked,
            RuleId,
            Reason,
            correlationId);
    }

    /// <summary>
    /// Projects this decision onto <see cref="AiPolicyDecision"/> for the audit and execution records.
    /// </summary>
    /// <remarks>
    /// A projection rather than a stored second copy, so the audit record cannot disagree with the
    /// decision that governed the execution. <see cref="AiPolicyDecision.HumanDecided"/> is left false
    /// and is correct as written: this record describes what <em>policy</em> decided, and a decision
    /// that is <see cref="AiGovernanceVerdict.HumanDecisionRequired"/> has not been decided by a human —
    /// it is waiting for one.
    /// </remarks>
    public AiPolicyDecision ToPolicyDecision() => new()
    {
        Allowed = IsAllowed,
        RulesApplied = RulesApplied,
        Reason = IsAllowed ? null : Reason,
    };
}
