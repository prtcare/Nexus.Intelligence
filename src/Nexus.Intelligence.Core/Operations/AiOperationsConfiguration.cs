using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Registry;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// The configuration shape of the operational plane: budget, reliability, circuit recovery and health
/// probing.
/// </summary>
/// <remarks>
/// <para>
/// <b>It exists because every threshold in this lane belongs to an operator.</b> The directive is
/// explicit that W7E must not invent business limits and must not hardcode reliability thresholds, and
/// the way that requirement is met is not by choosing careful constants — it is by having no constant
/// to choose. The types below carry the values; the contracts they parse into carry the semantics; and
/// the shipped defaults are the ones the contracts already document, reached here only when the
/// section is absent.
/// </para>
/// <para>
/// <b>An absent section is not an amnesty.</b> The budget plane's shipped posture refuses a priced
/// execution no rule covers, so an estate that configures nothing gets a refusal rather than an
/// unenforced ceiling. That is the same fail-closed starting state W7B and W7C shipped with, and it is
/// the reason this lane's defaults are not "permissive until configured".
/// </para>
/// <para>
/// <b>Mutable settable properties, confined to the read.</b> The binder needs them; everything
/// downstream is the immutable policy record. This is the same arrangement, and the same justification,
/// as <see cref="AiRegistryConfiguration"/>.
/// </para>
/// </remarks>
public sealed class AiOperationsConfiguration
{
    /// <summary>The configuration section this type binds from.</summary>
    public const string SectionName = "Ai:Operations";

    /// <summary>The operational budget ceiling table.</summary>
    public AiBudgetConfigurationEntry Budget { get; set; } = new();

    /// <summary>The reliability gate's thresholds and sample requirements.</summary>
    public AiReliabilityConfigurationEntry Reliability { get; set; } = new();

    /// <summary>How a route refused by the reliability gate is eventually asked again.</summary>
    public AiCircuitConfigurationEntry Recovery { get; set; } = new();

    /// <summary>Whether and how often the live health probes run.</summary>
    public AiHealthProbeConfigurationEntry Health { get; set; } = new();

    /// <summary>
    /// Builds the budget policy, validating it before returning.
    /// </summary>
    /// <remarks>
    /// Validated here rather than at first use, because a malformed ceiling table is a composition
    /// defect: a rule with no currency or a rule that permits what it bounds cannot be discovered by
    /// routing, which would only ever observe that some route was not refused.
    /// </remarks>
    /// <exception cref="InvalidOperationException">A rule is malformed or a name is not a known member.</exception>
    /// <exception cref="ArgumentException">The assembled policy fails its own validation.</exception>
    public AiOperationsBudgetPolicy BudgetPolicy()
    {
        var configured = Budget ?? new AiBudgetConfigurationEntry();

        var policy = new AiOperationsBudgetPolicy
        {
            Rules = [.. (configured.Rules ?? []).Select(ParseRule)],

            // The contract's own defaults, named here rather than repeated as literals. An estate that
            // wants the plane off says so in configuration; it does not reach that state by omission.
            Available = configured.Available ?? AiOperationsBudgetPolicy.Default.Available,
            OnUncoveredPricedExecution = ConfigurationEnum.Parse(
                configured.OnUncoveredPricedExecution,
                AiOperationsBudgetPolicy.Default.OnUncoveredPricedExecution,
                $"{SectionName}:Budget:OnUncoveredPricedExecution",
                "uncovered-execution behaviour"),
        };

        policy.Validate();

        return policy;
    }

    /// <summary>Builds the reliability policy, validating it before returning.</summary>
    /// <exception cref="InvalidOperationException">A duration is not a whole number of minutes.</exception>
    /// <exception cref="ArgumentException">The assembled policy fails its own validation.</exception>
    public AiReliabilityPolicy ReliabilityPolicy()
    {
        var configured = Reliability ?? new AiReliabilityConfigurationEntry();
        var defaults = AiReliabilityPolicy.Default;

        var policy = new AiReliabilityPolicy
        {
            Enabled = configured.Enabled ?? defaults.Enabled,
            MinimumSampleSize = configured.MinimumSampleSize ?? defaults.MinimumSampleSize,
            MinimumSuccessRate = configured.MinimumSuccessRate ?? defaults.MinimumSuccessRate,
            ConsecutiveFailureCeiling = configured.ConsecutiveFailureCeiling ?? defaults.ConsecutiveFailureCeiling,
            RequireEvidence = configured.RequireEvidence ?? defaults.RequireEvidence,
            EvidenceLifetime = configured.EvidenceLifetimeMinutes is { } minutes
                ? TimeSpan.FromMinutes(minutes)
                : defaults.EvidenceLifetime,
        };

        policy.Validate();

        return policy;
    }

    /// <summary>Builds the circuit policy, validating it before returning.</summary>
    /// <remarks>
    /// The recovery model's own parameters only. The conditions that open a circuit are the
    /// reliability policy's, above, and are deliberately not restated here.
    /// </remarks>
    /// <exception cref="InvalidOperationException">A duration is not a whole number of seconds.</exception>
    /// <exception cref="ArgumentException">The assembled policy fails its own validation.</exception>
    public AiCircuitPolicy CircuitPolicy()
    {
        var configured = Recovery ?? new AiCircuitConfigurationEntry();
        var defaults = AiCircuitPolicy.Default;

        var policy = new AiCircuitPolicy
        {
            Enabled = configured.Enabled ?? defaults.Enabled,
            Cooldown = configured.CooldownSeconds is { } seconds
                ? TimeSpan.FromSeconds(seconds)
                : defaults.Cooldown,
            ProbeAllowance = configured.ProbeAllowance ?? defaults.ProbeAllowance,
            ProbeSuccessesRequired = configured.ProbeSuccessesRequired ?? defaults.ProbeSuccessesRequired,
        };

        policy.Validate();

        return policy;
    }

    /// <summary>How many attempts the in-process reliability history retains per route.</summary>
    /// <remarks>
    /// Bounded, because an unbounded history is a memory leak that grows fastest on the estate with
    /// the most traffic — and the rate and the consecutive-failure run are both computed over a
    /// recent window, so unbounded retention buys nothing the gate reads.
    /// </remarks>
    public int ReliabilityHistoryCapacity =>
        Reliability?.HistoryCapacity is { } capacity && capacity > 0
            ? capacity
            : InMemoryAiReliabilityHistory.DefaultCapacity;

    /// <summary>How often the probe sweep runs, or null when probing is not composed.</summary>
    public TimeSpan? ProbeInterval => Health is { Enabled: true, IntervalSeconds: > 0 }
        ? TimeSpan.FromSeconds(Health.IntervalSeconds)
        : null;

    /// <summary>One rule, parsed and checked for the types the binder cannot express.</summary>
    private static AiOperationsBudgetRule ParseRule(AiBudgetRuleConfigurationEntry entry)
    {
        var ruleId = entry?.RuleId;

        if (string.IsNullOrWhiteSpace(ruleId) || !CapabilityId.IsValid(ruleId))
        {
            throw new InvalidOperationException(
                $"{SectionName}:Budget:Rules: '{ruleId}' is not a valid budget rule identifier. "
                + "The identifier appears on every verdict the rule produces, so a rule without one "
                + "produces verdicts nobody can trace back to a table entry.");
        }

        if (entry!.Capability is { Length: > 0 } capability && !CapabilityId.IsValid(capability))
        {
            throw new InvalidOperationException(
                $"{SectionName}:Budget:Rules:{ruleId}:Capability: '{capability}' is not a valid "
                + "capability identifier.");
        }

        return new AiOperationsBudgetRule
        {
            RuleId = ruleId,
            Capability = entry.Capability is { Length: > 0 } named ? CapabilityId.Parse(named) : (CapabilityId?)null,
            ProductId = entry.ProductId,
            TenantId = entry.TenantId,
            WorkspaceId = entry.WorkspaceId,
            ProviderId = entry.ProviderId,
            ModelId = entry.ModelId,

            // A ceiling the binder did not find is refused rather than defaulted to zero. Zero is a
            // ceiling that refuses everything priced at all, which is a real control an operator may
            // want — and it is one they must write down, not receive for having omitted a line.
            Ceiling = entry.Ceiling ?? throw new InvalidOperationException(
                $"{SectionName}:Budget:Rules:{ruleId}:Ceiling is not set. An unset ceiling would "
                + "default to zero and silently refuse every execution the rule covers."),

            Currency = entry.Currency ?? string.Empty,
            Period = ConfigurationEnum.Parse(
                entry.Period, AiBudgetPeriod.None, $"{SectionName}:Budget:Rules:{ruleId}:Period",
                "budget period"),
            OnExceeded = ConfigurationEnum.Parse(
                entry.OnExceeded, AiGovernanceVerdict.Block,
                $"{SectionName}:Budget:Rules:{ruleId}:OnExceeded", "governance verdict"),
            Rationale = entry.Rationale ?? string.Empty,
        };
    }
}

/// <summary>The budget table as configuration declares it.</summary>
public sealed class AiBudgetConfigurationEntry
{
    /// <summary>Whether the operational budget plane is evaluated at all. Absent means the shipped posture.</summary>
    public bool? Available { get; set; }

    /// <summary>What an uncovered priced execution means, by name. Absent means the shipped posture.</summary>
    public string? OnUncoveredPricedExecution { get; set; }

    /// <summary>The ceiling rules. Empty means nothing is covered.</summary>
    public List<AiBudgetRuleConfigurationEntry> Rules { get; set; } = [];
}

/// <summary>One ceiling rule as configuration declares it.</summary>
public sealed class AiBudgetRuleConfigurationEntry
{
    /// <summary>The rule's stable identifier. Required.</summary>
    public string? RuleId { get; set; }

    /// <summary>Restrict to a capability.</summary>
    public string? Capability { get; set; }

    /// <summary>Restrict to a product.</summary>
    public string? ProductId { get; set; }

    /// <summary>Restrict to a tenant.</summary>
    public string? TenantId { get; set; }

    /// <summary>Restrict to a workspace.</summary>
    public string? WorkspaceId { get; set; }

    /// <summary>Restrict to a provider.</summary>
    public string? ProviderId { get; set; }

    /// <summary>Restrict to a model.</summary>
    public string? ModelId { get; set; }

    /// <summary>The ceiling. Required — see the parse for why it is not defaulted.</summary>
    public decimal? Ceiling { get; set; }

    /// <summary>ISO 4217 currency of the ceiling. Required.</summary>
    public string? Currency { get; set; }

    /// <summary>The window the ceiling is measured over, by name. Absent means this execution alone.</summary>
    public string? Period { get; set; }

    /// <summary>What to return when the ceiling is exceeded, by name. Absent means refuse.</summary>
    public string? OnExceeded { get; set; }

    /// <summary>Why the ceiling is where it is. Required.</summary>
    public string? Rationale { get; set; }
}

/// <summary>The reliability gate as configuration declares it.</summary>
/// <remarks>
/// Every member is nullable, and null means "the contract's shipped value" rather than zero. The
/// difference matters for the thresholds: a null minimum success rate that became 0 would disable the
/// gate while reading exactly like one that had been configured, and the estate would have no way to
/// tell which had happened.
/// </remarks>
public sealed class AiReliabilityConfigurationEntry
{
    /// <summary>Whether the reliability gate runs at all. Absent means the shipped posture.</summary>
    public bool? Enabled { get; set; }

    /// <summary>The minimum attempts before the success rate is applied.</summary>
    public int? MinimumSampleSize { get; set; }

    /// <summary>The success rate below which a sufficiently sampled route is refused, in 0..1.</summary>
    public double? MinimumSuccessRate { get; set; }

    /// <summary>The consecutive-failure count at which a route is refused regardless of sample size.</summary>
    public int? ConsecutiveFailureCeiling { get; set; }

    /// <summary>Whether evidence is required before a route may be used.</summary>
    public bool? RequireEvidence { get; set; }

    /// <summary>How long an observation remains current, in minutes.</summary>
    public int? EvidenceLifetimeMinutes { get; set; }

    /// <summary>How many attempts per route the in-process history retains.</summary>
    public int? HistoryCapacity { get; set; }
}

/// <summary>Live health probing as configuration declares it.</summary>
/// <remarks>
/// <b>Disabled by default, and that is the honest composition rather than a cautious one.</b> The
/// estate ships no probe that can conclude anything without a provider credential, and the historical
/// credential is under a human rotation hold. An estate that enables this interval without registering
/// a probe gets a sweep that runs on schedule and publishes the declared snapshot unchanged — which
/// is a visible, running, inconclusive probe rather than a silent absence.
/// </remarks>
public sealed class AiHealthProbeConfigurationEntry
{
    /// <summary>Whether the probe sweep is composed.</summary>
    public bool Enabled { get; set; }

    /// <summary>How often the sweep runs, in seconds.</summary>
    public int IntervalSeconds { get; set; } = 60;
}

/// <summary>The recovery model as configuration declares it.</summary>
/// <remarks>
/// <para>
/// <b>Every member is nullable, and null means "the contract's shipped value" rather than zero</b>,
/// which is the convention the reliability entry above already follows. Zero is a meaningful and
/// dangerous value for each of these — a zero cooldown is a circuit that never asks a provider to
/// stop — so it must be written down deliberately rather than arrived at by omission. It is refused
/// outright by <see cref="AiCircuitPolicy.Validate"/> when it is.
/// </para>
/// <para>
/// <b>There is no threshold here for opening a circuit.</b> Those are the reliability entry's, so
/// that one number has one home. This section answers only: once refused, how long, how many calls,
/// and how many of them must work.
/// </para>
/// </remarks>
public sealed class AiCircuitConfigurationEntry
{
    /// <summary>Whether the recovery model is applied. False restores the pre-recovery behaviour.</summary>
    public bool? Enabled { get; set; }

    /// <summary>How long a route stays refused before it may be probed.</summary>
    public int? CooldownSeconds { get; set; }

    /// <summary>How many calls a half-open route may be given.</summary>
    public int? ProbeAllowance { get; set; }

    /// <summary>How many of those must succeed before the route is fully eligible again.</summary>
    public int? ProbeSuccessesRequired { get; set; }
}
