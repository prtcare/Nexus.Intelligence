namespace Nexus.Intelligence.Contracts;

/// <summary>
/// Decides whether a proposed AI execution may proceed, and on what terms.
/// </summary>
/// <remarks>
/// <para>
/// <b>Deterministic and total.</b> The same request and the same attestation produce the same decision
/// on every call, on every machine, with no network, no clock and no randomness. That is not an
/// implementation detail of the shipped evaluator — it is the contract, because a governance decision
/// that can differ between two identical requests cannot be audited: a reviewer comparing two records
/// could not tell a policy change from a flake.
/// </para>
/// <para>
/// <b>Synchronous on purpose.</b> There is no asynchronous overload and none may be added. An
/// asynchronous governance gate is a gate that can be awaited alongside a provider call, and the first
/// implementation to do that has made the decision depend on something outside the policy table. The
/// signature is the enforcement.
/// </para>
/// <para>
/// <b>AI Governance is subordinate to Platform Governance, and the signature is where that lives.</b>
/// <see cref="Evaluate"/> requires an <see cref="AiPlatformGovernanceAttestation"/>, so there is no
/// code path to an AI verdict that has not been given the platform's decision. The implementation
/// composes the two most-restrictively, so an AI verdict of <c>ALLOW</c> cannot make a platform
/// refusal permitted.
/// </para>
/// <para>
/// <b>What this cannot do, by construction.</b> An implementation of this interface cannot merge Git,
/// deploy, alter protected architecture, resolve a credential or bypass Platform Governance: it
/// receives no credential, holds no credential reference, has no client, and its only output is a
/// value of <see cref="AiGovernanceDecision"/> — a record with a verdict, a rule identifier and a
/// reason. There is nothing on that record a caller could execute with.
/// </para>
/// </remarks>
public interface IAiGovernanceEvaluator
{
    /// <summary>
    /// Evaluates a proposed execution against the policy, under the platform's determination.
    /// </summary>
    /// <param name="request">What is proposed.</param>
    /// <param name="platform">
    /// What deterministic Platform Governance decided about the action this execution belongs to, or
    /// <see cref="AiPlatformGovernanceAttestation.NotApplicable"/> when the execution is attached to no
    /// platform action.
    /// </param>
    /// <returns>The decision. Never <see langword="null"/>.</returns>
    AiGovernanceDecision Evaluate(
        AiGovernanceEvaluationRequest request,
        AiPlatformGovernanceAttestation platform);
}
