namespace Nexus.Intelligence.Contracts;

/// <summary>
/// A cost ceiling, with the verdict to return when it is exceeded.
/// </summary>
/// <remarks>
/// <para>
/// A <b>record in the policy</b>, not a number in code. The directive's "prefer registries and policy
/// records over hardcoded provider and model lists" applies to budgets for the same reason it applies
/// to models: a ceiling compiled into an assembly cannot be changed without shipping one, and the
/// person who owns the cost cannot change it.
/// </para>
/// <para>
/// <see cref="OnExceeded"/> is a verdict and <b>may not be <see cref="AiGovernanceVerdict.Allow"/></b>.
/// A budget rule that allows when its ceiling is exceeded is not a rule; it is a comment. The
/// validation refuses it at composition rather than letting it sit in the table looking like a control.
/// It may be <see cref="AiGovernanceVerdict.HumanDecisionRequired"/> — "this is over budget, a person
/// decides" is a legitimate and common posture — and that is the shape which proves a human-required
/// decision does not decay into an allow.
/// </para>
/// </remarks>
public sealed record AiGovernanceBudgetRule
{
    /// <summary>The rule's stable identifier. Validated against the shared identifier format.</summary>
    public required string RuleId { get; init; }

    /// <summary>The capability this rule governs. <see langword="null"/> matches every capability.</summary>
    public CapabilityId? Capability { get; init; }

    /// <summary>The product this rule governs. <see langword="null"/> matches every product.</summary>
    public string? ProductId { get; init; }

    /// <summary>The ceiling, in <see cref="Currency"/>.</summary>
    public required decimal Ceiling { get; init; }

    /// <summary>ISO 4217 currency of <see cref="Ceiling"/>.</summary>
    public required string Currency { get; init; }

    /// <summary>What to return when the ceiling is exceeded. Never <see cref="AiGovernanceVerdict.Allow"/>.</summary>
    public AiGovernanceVerdict OnExceeded { get; init; } = AiGovernanceVerdict.Block;

    /// <summary>Why the ceiling is where it is. Required, so the table is reviewable.</summary>
    public required string Rationale { get; init; }

    /// <summary>True when this rule applies to a request's capability and product.</summary>
    /// <remarks>
    /// A rule with no capability and no product is a catch-all; a rule with either is scoped. Both
    /// must match when present, so specificity narrows rather than widens.
    /// </remarks>
    public bool Applies(CapabilityId capability, string? productId)
    {
        ArgumentNullException.ThrowIfNull(capability);

        if (Capability is not null && Capability != capability)
        {
            return false;
        }

        return ProductId is null || string.Equals(ProductId, productId, StringComparison.Ordinal);
    }
}

/// <summary>What is known about a tool's effect, as a governance fact.</summary>
/// <remarks>
/// The register of tool effects. A tool the register does not know has an <em>unknown</em> effect, and
/// the evaluator treats that as more severe than any known one — see
/// <see cref="AiGovernanceRules.ToolUnknown"/>. The failure mode of a tool list is a newly registered
/// tool being permitted by omission; treating ignorance as the worst case inverts that.
/// </remarks>
public sealed record AiGovernanceToolRule
{
    /// <summary>The rule's stable identifier.</summary>
    public required string RuleId { get; init; }

    /// <summary>The tool identifier this rule governs.</summary>
    public required string ToolId { get; init; }

    /// <summary>How severe the tool's effect is.</summary>
    public required ToolSideEffectClass SideEffect { get; init; }

    /// <summary>True when a human must approve every call to this tool, whatever the profile says.</summary>
    public bool RequiresHumanApproval { get; init; }

    /// <summary>Why the tool is classified as it is.</summary>
    public required string Rationale { get; init; }
}

/// <summary>
/// A declared reason for a human to decide, scoped to a subject.
/// </summary>
/// <remarks>
/// Escalation is expressed as a record rather than as a method so that "which executions need a human"
/// is answerable by reading a table rather than by reading the engine. A rule matches on the domain it
/// names and, optionally, a capability and a classification floor; the most specific match is not
/// special-cased, because every matching rule escalates and a second match changes nothing.
/// </remarks>
public sealed record AiGovernanceEscalationRule
{
    /// <summary>The rule's stable identifier.</summary>
    public required string RuleId { get; init; }

    /// <summary>The governance domain this rule escalates.</summary>
    public required AiGovernanceSubject Subject { get; init; }

    /// <summary>The capability this rule is scoped to, or <see langword="null"/> for any.</summary>
    public CapabilityId? Capability { get; init; }

    /// <summary>
    /// The classification at or above which this rule escalates, or <see langword="null"/> for any.
    /// </summary>
    public DataClassification? AtOrAbove { get; init; }

    /// <summary>Why a human must decide. Required: an escalation without a reason is not reviewable.</summary>
    public required string Reason { get; init; }

    /// <summary>True when this rule escalates a request.</summary>
    public bool Applies(AiGovernanceSubject subject, CapabilityId capability, DataClassification classification)
    {
        ArgumentNullException.ThrowIfNull(capability);

        if (Subject != subject)
        {
            return false;
        }

        if (Capability is not null && Capability != capability)
        {
            return false;
        }

        return AtOrAbove is null || classification.IsAtLeast(AtOrAbove.Value);
    }
}

/// <summary>
/// The policy AI Governance decides from.
/// </summary>
/// <remarks>
/// <para>
/// <b>Every list here is data supplied to the engine; the engine holds none of it.</b> There is no
/// model identifier, no provider name, no agent name and no tool identifier in
/// <see cref="DeterministicAiGovernanceEvaluator"/> — they are all resolved through
/// <see cref="Register"/> or matched against the records in this type. That is the directive's
/// "registries and policy records over hardcoded lists", made structural rather than promised.
/// </para>
/// <para>
/// <b><see cref="Default"/> is closed.</b> It carries the prohibition baseline, the conservative
/// exposure table, the empty register and a trust floor that refuses remote egress to anything
/// unassessed. It therefore refuses every execution that names a model, provider, agent or prompt,
/// because none is registered yet. That is the intended state of an estate whose registry lane has not
/// run: nothing is approved, so nothing proceeds, and the block is deterministic and immediately
/// explicable.
/// </para>
/// </remarks>
public sealed record AiGovernancePolicy
{
    /// <summary>The prohibition register. The authority for AI-prohibited surfaces and capabilities.</summary>
    public required AiDependencyRegistry Dependencies { get; init; }

    /// <summary>The capability register. The authority for what may be served at all.</summary>
    public required AiCapabilityRegister Capabilities { get; init; }

    /// <summary>The exposure table. The authority for what content may reach which destination class.</summary>
    public required DataExposurePolicy Exposure { get; init; }

    /// <summary>The governed resources. The authority for which models, providers, agents and prompts exist.</summary>
    public required IAiGovernanceRegister Register { get; init; }

    /// <summary>Cost ceilings, as records.</summary>
    public IReadOnlyList<AiGovernanceBudgetRule> Budgets { get; init; } = [];

    /// <summary>Tool effect classifications, as records.</summary>
    public IReadOnlyList<AiGovernanceToolRule> Tools { get; init; } = [];

    /// <summary>Declared reasons for a human to decide.</summary>
    public IReadOnlyList<AiGovernanceEscalationRule> Escalations { get; init; } = [];

    /// <summary>
    /// The trust floor a provider must reach to receive content over the network.
    /// </summary>
    /// <remarks>
    /// A floor and not a switch: raising it refuses more, lowering it refuses less, and there is no
    /// value that permits an unassessed provider — <see cref="AiProviderTrustTier.Untrusted"/> is the
    /// lowest tier and a record defaults to it, so a provider nobody assessed cannot reach the floor by
    /// the floor being set low.
    /// </remarks>
    public AiProviderTrustTier MinimumTrustForRemoteEgress { get; init; } = AiProviderTrustTier.Approved;

    /// <summary>
    /// True when a priced execution with no matching budget rule is refused rather than allowed.
    /// </summary>
    /// <remarks>
    /// <b>Defaults to true, and the default is the point.</b> "No ceiling covers this" and "this has no
    /// ceiling" are the same statement, and the second is a finding. A policy that permitted an
    /// uncovered execution would make the budget table's coverage a matter of which rules someone
    /// remembered to write, with the omission invisible.
    /// </remarks>
    public bool RequireBudgetRuleForPricedExecution { get; init; } = true;

    /// <summary>The policy that applies when none is configured: closed, and it refuses unregistered resources.</summary>
    public static AiGovernancePolicy Default() => new()
    {
        Dependencies = AiDependencyRegistry.Empty,
        Capabilities = AiCapabilityRegister.Bootstrap(),
        Exposure = DataExposurePolicy.Default(),
        Register = EmptyAiGovernanceRegister.Instance,
    };

    /// <summary>
    /// Validates the whole policy, throwing on the first defect.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Called by the evaluator's constructor, so a malformed policy fails at composition rather than on
    /// the first request that happens to reach the broken record — the same rule
    /// <see cref="AiDependencyRegistry"/> applies to its own declarations.
    /// </para>
    /// <para>
    /// It is public as well as called, because each refusal is a governed property worth asserting
    /// directly: a test that a budget rule cannot allow on exceed is clearer than a test that a
    /// constructed policy happens to throw.
    /// </para>
    /// </remarks>
    /// <exception cref="ArgumentException">A record is malformed or internally inconsistent.</exception>
    public void Validate()
    {
        ArgumentNullException.ThrowIfNull(Dependencies);
        ArgumentNullException.ThrowIfNull(Capabilities);
        ArgumentNullException.ThrowIfNull(Exposure);
        ArgumentNullException.ThrowIfNull(Register);
        ArgumentNullException.ThrowIfNull(Budgets);
        ArgumentNullException.ThrowIfNull(Tools);
        ArgumentNullException.ThrowIfNull(Escalations);

        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (var budget in Budgets)
        {
            RequireRecordRuleId(budget?.RuleId, "budget", seen);

            if (budget!.Ceiling < 0m)
            {
                throw new ArgumentException(
                    $"Budget rule '{budget.RuleId}' has a negative ceiling. A negative ceiling is not a " +
                    "budget, it is a rule that refuses everything priced at all, expressed as arithmetic.",
                    nameof(Budgets));
            }

            if (string.IsNullOrWhiteSpace(budget.Currency))
            {
                throw new ArgumentException(
                    $"Budget rule '{budget.RuleId}' names no currency. A ceiling without a currency cannot be " +
                    "compared against a cost, and comparing across currencies silently is the defect the field " +
                    "exists to prevent.",
                    nameof(Budgets));
            }

            if (budget.OnExceeded is AiGovernanceVerdict.Allow)
            {
                throw new ArgumentException(
                    $"Budget rule '{budget.RuleId}' allows when its ceiling is exceeded. A ceiling that " +
                    "permits what exceeds it is not a control; it is a comment that reads like one. Use " +
                    $"{nameof(AiGovernanceVerdict.Block)} or {nameof(AiGovernanceVerdict.HumanDecisionRequired)}.",
                    nameof(Budgets));
            }

            if (string.IsNullOrWhiteSpace(budget.Rationale))
            {
                throw new ArgumentException(
                    $"Budget rule '{budget.RuleId}' has no rationale. A ceiling nobody explained cannot be " +
                    "reviewed when someone asks why it is where it is.",
                    nameof(Budgets));
            }
        }

        foreach (var tool in Tools)
        {
            RequireRecordRuleId(tool?.RuleId, "tool", seen);

            if (string.IsNullOrWhiteSpace(tool!.ToolId))
            {
                throw new ArgumentException(
                    $"Tool rule '{tool.RuleId}' names no tool. A tool classification without a tool is " +
                    "unreachable, so it can only ever mislead a reader into thinking a tool is covered.",
                    nameof(Tools));
            }

            if (!Enum.IsDefined(tool.SideEffect))
            {
                throw new ArgumentException(
                    $"Tool rule '{tool.RuleId}' declares an undefined side-effect class '{tool.SideEffect}'.",
                    nameof(Tools));
            }
        }

        foreach (var escalation in Escalations)
        {
            RequireRecordRuleId(escalation?.RuleId, "escalation", seen);

            if (!Enum.IsDefined(escalation!.Subject))
            {
                throw new ArgumentException(
                    $"Escalation rule '{escalation.RuleId}' names an undefined governance subject.",
                    nameof(Escalations));
            }

            if (escalation.AtOrAbove is not null && !Enum.IsDefined(escalation.AtOrAbove.Value))
            {
                throw new ArgumentException(
                    $"Escalation rule '{escalation.RuleId}' names an undefined classification.",
                    nameof(Escalations));
            }

            if (string.IsNullOrWhiteSpace(escalation.Reason))
            {
                throw new ArgumentException(
                    $"Escalation rule '{escalation.RuleId}' gives no reason. A rule that stops an execution " +
                    "for a human without saying why is a rule a person will route around.",
                    nameof(Escalations));
            }
        }

        if (!Enum.IsDefined(MinimumTrustForRemoteEgress))
        {
            throw new ArgumentException(
                $"The policy names an undefined trust floor '{MinimumTrustForRemoteEgress}'.", nameof(MinimumTrustForRemoteEgress));
        }
    }

    /// <summary>
    /// The most specific budget rule covering a request, or <see langword="null"/> when none does.
    /// </summary>
    /// <remarks>
    /// Specificity is <em>capability and product named</em> over <em>capability named</em> over
    /// <em>product named</em> over <em>neither</em>, with rule identifier breaking ties. The order is
    /// fixed here rather than left to declaration order, so moving a rule within the table cannot
    /// change which ceiling applies — a table whose meaning depends on line order is a table nobody can
    /// review.
    /// </remarks>
    public AiGovernanceBudgetRule? BudgetFor(CapabilityId capability, string? productId)
    {
        ArgumentNullException.ThrowIfNull(capability);

        return Budgets
            .Where(r => r.Applies(capability, productId))
            .OrderByDescending(r => (r.Capability is not null ? 2 : 0) + (r.ProductId is not null ? 1 : 0))
            .ThenBy(r => r.RuleId, StringComparer.Ordinal)
            .FirstOrDefault();
    }

    /// <summary>The tool's classification, or <see langword="null"/> when the register does not know it.</summary>
    public AiGovernanceToolRule? ToolFor(string? toolId)
    {
        if (string.IsNullOrWhiteSpace(toolId))
        {
            return null;
        }

        return Tools.FirstOrDefault(r => string.Equals(r.ToolId, toolId, StringComparison.Ordinal));
    }

    /// <summary>Every escalation rule that matches a request.</summary>
    public IReadOnlyList<AiGovernanceEscalationRule> EscalationsFor(
        AiGovernanceSubject subject,
        CapabilityId capability,
        DataClassification classification)
        => Escalations
            .Where(r => r.Applies(subject, capability, classification))
            .OrderBy(r => r.RuleId, StringComparer.Ordinal)
            .ToArray();

    private static void RequireRecordRuleId(string? ruleId, string kind, HashSet<string> seen)
    {
        if (!CapabilityId.IsValid(ruleId))
        {
            throw new ArgumentException(
                $"A {kind} rule has an invalid identifier '{ruleId}'. Rule identifiers use the same stable " +
                "<domain>.<object> format as capability identifiers, so a malformed one cannot be resolved " +
                "from an audit record.",
                kind);
        }

        if (AiGovernanceRules.All.Contains(ruleId!, StringComparer.Ordinal))
        {
            throw new ArgumentException(
                $"The {kind} rule '{ruleId}' uses a rule identifier the governance engine itself defines. " +
                "A policy record must not be able to impersonate an engine rule: the audit record would then " +
                "be unable to say whether the engine or the policy refused the execution.",
                kind);
        }

        if (!seen.Add(ruleId!))
        {
            throw new ArgumentException(
                $"The rule identifier '{ruleId}' is declared more than once in this policy. Two records under " +
                "one identifier make the effective rule depend on which list was searched first.",
                kind);
        }
    }
}
