namespace Nexus.Intelligence.Contracts;

/// <summary>
/// What the router is trying to optimise, once governance and eligibility have finished refusing.
/// </summary>
/// <remarks>
/// <para>
/// <b>An objective chooses a ranking, never a permission.</b> Every member here ranks a set that has
/// already survived the eligibility filters and per-candidate governance, so no choice of objective
/// can route to a model governance refused. That ordering is the directive's "deterministic governance
/// always wins" expressed as structure rather than as a rule the ranker follows: the ranker is handed
/// only permitted candidates, so it has nothing else it could do.
/// </para>
/// <para>
/// The vocabulary is configuration. An operator changes the estate's routing preference by editing a
/// value, and the ranking weights that value selects are data — so there is no code change, and no
/// code-level default that quietly disagrees with the configured intent.
/// </para>
/// </remarks>
public enum AiRoutingObjective
{
    /// <summary>
    /// A configured blend of cost, reliability, reasoning headroom, health and priority.
    /// </summary>
    /// <remarks>
    /// The default, and the only member that is a compromise rather than a single criterion. It exists
    /// because the honest answer to "what should we optimise?" is usually "all of it, in proportion",
    /// and an estate forced to pick <see cref="CheapestEligible"/> or <see cref="HighestReliability"/>
    /// would pick one and silently abandon the other.
    /// </remarks>
    Balanced = 0,

    /// <summary>The lowest predicted cost among eligible routes.</summary>
    CheapestEligible = 1,

    /// <summary>Cost, but weighted against trust, health and priority. Favours cheap routes that are trusted.</summary>
    CheapestReliable = 2,

    /// <summary>The most trusted eligible route, with cost a minor component.</summary>
    HighestReliability = 3,

    /// <summary>The greatest reasoning headroom available, with cost a minor component.</summary>
    HighestReasoning = 4,

    /// <summary>
    /// Priority first, then weight. An operator's explicit ordering, with no scoring inference.
    /// </summary>
    /// <remarks>
    /// The objective for an estate that wants routing to be an ordered list rather than a computation.
    /// It ranks on <see cref="AiProviderRegistration.Priority"/> and
    /// <see cref="AiProviderRegistration.Weight"/> alone, so the outcome is exactly what the operator
    /// wrote down and is explicable without reference to any scoring rule.
    /// </remarks>
    ConfiguredOrder = 5,
}

/// <summary>What a routing request concluded.</summary>
/// <remarks>
/// <b>Four refusals and one success, and the refusals are distinct because the remedies are.</b>
/// A capability nobody serves is answered by building something; an estate with no eligible model is
/// answered by an operator turning something on; a governance block is answered by changing the
/// request or the approval; and a human-required decision is answered by a person deciding. Collapsing
/// them into a boolean would leave a caller unable to tell which act was needed.
/// </remarks>
public enum AiRoutingStatus
{
    /// <summary>A model was selected and governance permitted it.</summary>
    Routed = 0,

    /// <summary>No registered model claims the capability. Answered by registering one.</summary>
    CapabilityNotFound = 1,

    /// <summary>Models claim the capability, but none survived the filters.</summary>
    NoEligibleModel = 2,

    /// <summary>Governance refused, and the refusal is a property of the request rather than of one route.</summary>
    GovernanceBlocked = 3,

    /// <summary>A named human must decide before this work may be routed at all.</summary>
    HumanDecisionRequired = 4,
}

/// <summary>Why one model/provider route was not selected.</summary>
/// <remarks>
/// <para>
/// <b>A closed vocabulary rather than a message.</b> The reasons are what a caller's "why did this not
/// run?" is answered from, and a caller that has to parse prose to find out is a caller that will one
/// day parse it wrongly. Each member names a distinct remedy: turn it on, approve it, wait for it,
/// raise the ceiling, or register the thing that does not exist.
/// </para>
/// <para>
/// <see cref="AiRoutingRejection.Detail"/> carries the values — which ceiling, by how much — because a
/// reason code says what kind of problem it is and the detail says which instance of it.
/// </para>
/// </remarks>
public enum AiRoutingRejectionReason
{
    /// <summary>Nothing is registered under the model identifier.</summary>
    ModelNotRegistered = 0,

    /// <summary>Nothing is registered under the provider identifier the model names.</summary>
    ProviderNotRegistered = 1,

    /// <summary>The model is registered but switched off.</summary>
    ModelDisabled = 2,

    /// <summary>The provider is registered but switched off.</summary>
    ProviderDisabled = 3,

    /// <summary>The model's lifecycle state is not one that may be routed to.</summary>
    ModelLifecycleNotRoutable = 4,

    /// <summary>The health source reports the model unroutable.</summary>
    ModelUnhealthy = 5,

    /// <summary>The health source reports the provider unroutable.</summary>
    ProviderUnhealthy = 6,

    /// <summary>The model is registered, but does not claim the requested capability.</summary>
    CapabilityNotDeclaredByModel = 7,

    /// <summary>The provider is registered, but does not claim the requested capability.</summary>
    CapabilityNotDeclaredByProvider = 8,

    /// <summary>The model does not state an input limit, so no fit can be checked.</summary>
    ContextLimitUnknown = 9,

    /// <summary>The input plus the output reserve does not fit the model's window.</summary>
    ContextTooSmall = 10,

    /// <summary>The model does not state an output limit, so no fit can be checked.</summary>
    OutputLimitUnknown = 11,

    /// <summary>The requested output exceeds what the model will emit.</summary>
    OutputLimitExceedsModel = 12,

    /// <summary>The model does not accept the modality of its input.</summary>
    InputModalityUnsupported = 13,

    /// <summary>The model does not produce the modality the caller requires.</summary>
    OutputModalityUnsupported = 14,

    /// <summary>The model's reasoning class is below what the capability requires.</summary>
    ReasoningInsufficient = 15,

    /// <summary>The predicted cost exceeds the caller's ceiling.</summary>
    CallerCostCeilingExceeded = 16,

    /// <summary>The caller stated a cost ceiling and the route's cost cannot be predicted.</summary>
    CostUnknownAgainstCallerCeiling = 17,

    /// <summary>AI Governance blocked this route.</summary>
    GovernanceBlocked = 18,

    /// <summary>AI Governance requires a human decision about this route.</summary>
    GovernanceHumanDecisionRequired = 19,

    // --- W7E: the operational stage -----------------------------------------------------------------
    //
    // Appended with explicit numbering, and the existing members above are untouched. Renumbering an
    // enum member is a silent change to the meaning of every value already persisted under the old
    // numbering, and the defect is invisible in the diff because the names still read correctly.

    /// <summary>The model does not declare support for the processing tier the work requires.</summary>
    /// <remarks>
    /// Produced only from declared tier metadata on the model registration. Never inferred from a
    /// model identifier, a provider name or a price, because a rule that read a vendor's name to
    /// decide what it supports would mis-classify the next model whose name resembled it.
    /// </remarks>
    ProcessingTierUnsupported = 20,

    /// <summary>Observed reliability is below the configured floor, on a sufficient sample.</summary>
    /// <remarks>
    /// Evidence-backed by construction: this member cannot be produced without observed attempts,
    /// which is what makes it a finding rather than a configuration-only guess.
    /// </remarks>
    ReliabilityTooLow = 21,

    /// <summary>The policy requires evidence and this route has none yet.</summary>
    /// <remarks>
    /// Distinct from <see cref="ReliabilityTooLow"/> because "we do not know" and "we know it is
    /// bad" are different findings with different remedies. Produced only when the configured policy
    /// sets <see cref="AiReliabilityPolicy.RequireEvidence"/>.
    /// </remarks>
    ReliabilityEvidenceMissing = 22,

    /// <summary>No operational budget rule covers this priced route, and the policy refuses that.</summary>
    BudgetUncovered = 23,

    /// <summary>The route would exceed a covering operational budget ceiling.</summary>
    BudgetExceeded = 24,

    // --- W7G-R: the recovery model -------------------------------------------------------------------
    //
    // Appended, per the rule above. CircuitOpen is deliberately a member of its own rather than a
    // second use of ReliabilityTooLow: the two say different things and have different remedies.
    // ReliabilityTooLow is a measurement — the route's observed behaviour is bad. CircuitOpen is a
    // decision — the estate has stopped asking, for a configured while, and will ask again afterwards.
    // Reported under one name, an operator cannot tell a route that will be probed in a minute from
    // one that will never be used again.

    /// <summary>
    /// The route's circuit is open. Routing refuses it until the configured cooldown has elapsed.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>It is a refusal with an end.</b> The circuit's state, the failure that opened it, when the
    /// cooldown elapses and how much probe traffic remains are all on the
    /// <see cref="AiCircuitSnapshot"/> carried by this rejection and by the verdict — so a consumer
    /// of this vocabulary is never told "refused" without also being told what would change it.
    /// </para>
    /// <para>
    /// It is produced only by the operational stage's circuit gate, which is only reached by a
    /// candidate that governance has already permitted. A governance refusal is therefore never
    /// reported as a circuit refusal, and a blocked route cannot be released by a cooldown.
    /// </para>
    /// </remarks>
    CircuitOpen = 25,
}
