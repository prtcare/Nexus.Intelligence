using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Governance;

/// <summary>
/// What one governed provider invocation produced, whether or not it was made.
/// </summary>
/// <remarks>
/// <see cref="Invoked"/> is the load-bearing member. A blocked execution and an execution that reached
/// the provider and returned nothing are different facts, and a caller that cannot tell them apart will
/// report the second as the first — "the request was refused" when in truth the provider was called and
/// answered emptily. The flag is carried rather than inferred from <see cref="Result"/> being
/// <see langword="null"/>, because a provider that legitimately returns a null payload is not a
/// provider that was never called.
/// </remarks>
public sealed record GovernedInvocationOutcome<T>
{
    /// <summary>What governance decided. Always present.</summary>
    public required AiGovernanceDecision Decision { get; init; }

    /// <summary>True when the provider delegate was actually called.</summary>
    public required bool Invoked { get; init; }

    /// <summary>The provider's result, present exactly when <see cref="Invoked"/> is true.</summary>
    public T? Result { get; init; }

    /// <summary>True when the execution proceeded.</summary>
    public bool IsAllowed => Decision.IsAllowed;

    /// <summary>The typed failure for a refusal, or <see langword="null"/> when the execution proceeded.</summary>
    public AiFailure? ToFailure(string correlationId) => Decision.ToFailure(correlationId);
}

/// <summary>
/// The single place a provider is called from behind AI Governance.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why a seam rather than a wrapper type.</b> The directive requires that prohibited data
/// classifications can be blocked <em>before provider invocation</em>, and "before" is only provable if
/// there is one point where the decision precedes the call. A decorator over
/// <c>IModelGateway</c> would put the gate in the resolution graph, where a second registration or a
/// direct construction reaches the provider without passing it. This method takes the invocation as a
/// delegate, so a caller that wants to reach a provider through governance has to hand over the call it
/// wants governed — and the order is visible in five lines rather than distributed across the
/// composition root.
/// </para>
/// <para>
/// <b>It is deliberately not a class with state.</b> There is no policy, no cache and no memoisation
/// here: a decision is made per invocation from the evaluator's policy, and a memoised governance
/// decision would let a policy change apply to some requests and not others depending on what had been
/// asked before. Governance decisions are cheap — they read tables — and the cost of recomputing them
/// is the price of the property that the same request always gets the same answer.
/// </para>
/// <para>
/// <b>An escalation does not proceed.</b> Only <see cref="AiGovernanceVerdict.Allow"/> reaches the
/// delegate. <see cref="AiGovernanceVerdict.HumanDecisionRequired"/> returns without invoking, because
/// a human-required decision that still called the provider would have made the decision after the
/// thing it was deciding about had already happened.
/// </para>
/// </remarks>
public static class GovernedProviderInvocation
{
    /// <summary>
    /// Evaluates the request and calls the provider only if governance allowed it.
    /// </summary>
    /// <typeparam name="T">The provider's result type.</typeparam>
    /// <param name="evaluator">The governance engine.</param>
    /// <param name="request">What is proposed.</param>
    /// <param name="platform">
    /// What deterministic Platform Governance decided about the action this execution belongs to.
    /// Required, and deliberately not defaulted: an overload that omitted it would be the code path
    /// that reaches a provider without the platform's decision having been supplied.
    /// </param>
    /// <param name="providerInvocation">The call to make, and the only thing governance gates.</param>
    /// <param name="cancellationToken">Cancels the provider call, not the decision — the decision is synchronous.</param>
    /// <returns>The outcome, with <see cref="GovernedInvocationOutcome{T}.Invoked"/> stating whether the provider ran.</returns>
    /// <exception cref="ArgumentNullException">An argument is null.</exception>
    public static async Task<GovernedInvocationOutcome<T>> InvokeAsync<T>(
        IAiGovernanceEvaluator evaluator,
        AiGovernanceEvaluationRequest request,
        AiPlatformGovernanceAttestation platform,
        Func<CancellationToken, Task<T>> providerInvocation,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(evaluator);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(platform);
        ArgumentNullException.ThrowIfNull(providerInvocation);

        // Synchronous, and before the delegate is touched. Nothing in the evaluator can await, hold a
        // client or reach the network, so there is no way for this call to have partially invoked the
        // provider by the time it returns a verdict.
        var decision = evaluator.Evaluate(request, platform);

        if (!decision.IsAllowed)
        {
            return new GovernedInvocationOutcome<T>
            {
                Decision = decision,
                Invoked = false,
            };
        }

        var result = await providerInvocation(cancellationToken).ConfigureAwait(false);

        return new GovernedInvocationOutcome<T>
        {
            Decision = decision,
            Invoked = true,
            Result = result,
        };
    }
}
