namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The port through which current provider and model health enters a routing decision.
/// </summary>
/// <remarks>
/// <para>
/// <b>Health is an input and not a registry field.</b> A registration states what a provider is; this
/// states how it is doing, and the two change on completely different timescales — a registration
/// changes when an operator edits configuration, health changes between one call and the next. Putting
/// health on the registration would make the registry a cache of a fact that goes stale silently.
/// </para>
/// <para>
/// <b>Synchronous, and deliberately so.</b> Routing must be a pure, reproducible function of its
/// inputs; an asynchronous health source invites an implementation that reaches the network from
/// inside a routing decision, which would make the same request produce different outcomes on
/// different days and put a network call in the path the governance gate is supposed to precede. An
/// implementation that needs live probing populates a snapshot elsewhere and answers from it here.
/// </para>
/// <para>
/// <b>Absence of health is not health.</b> Every implementation must answer for an identifier it has
/// never heard of, and the only honest answer is <see cref="AiModelHealthState.Unknown"/> — which is
/// not routable. A source that returned <see cref="AiModelHealthState.Available"/> for anything it did
/// not recognise would turn "we have no information" into "this is working", and the estate's first
/// routing decision would be made on a fabricated fact.
/// </para>
/// </remarks>
public interface IAiModelHealthSource
{
    /// <summary>How a specific model on a specific provider is doing.</summary>
    AiModelHealthState GetModelHealth(string modelId, string providerId);

    /// <summary>How a provider as a whole is doing, across all of its models.</summary>
    /// <remarks>
    /// Asked separately from the model's health because the two fail independently: a provider can be
    /// entirely unreachable while one of its models is fine in principle, and a single model can be
    /// withdrawn while the provider serves its others normally. Both gates apply and the narrower wins.
    /// </remarks>
    AiModelHealthState GetProviderHealth(string providerId);
}

/// <summary>
/// The health source that has been told nothing, and therefore reports every route unroutable.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the correct starting state, not a placeholder.</b> An estate that has not wired a health
/// source has no basis on which to claim any route is working, and the two ways to proceed are to
/// refuse everything or to assume everything. Assuming everything is the failure mode that produces a
/// production incident on the first request after a deploy, so this type refuses everything, and the
/// refusal is loud, uniform and immediately diagnosable.
/// </para>
/// <para>
/// The remedy is to supply a real source — a configured snapshot of operator-declared state, or a
/// probe-backed one — which is a deliberate act with a record, rather than the absence of an act.
/// </para>
/// </remarks>
public sealed class UnreportedAiHealthSource : IAiModelHealthSource
{
    /// <summary>The single instance. The source is stateless.</summary>
    public static UnreportedAiHealthSource Instance { get; } = new();

    /// <inheritdoc />
    public AiModelHealthState GetModelHealth(string modelId, string providerId)
        => AiModelHealthState.Unknown;

    /// <inheritdoc />
    public AiModelHealthState GetProviderHealth(string providerId)
        => AiModelHealthState.Unknown;
}
