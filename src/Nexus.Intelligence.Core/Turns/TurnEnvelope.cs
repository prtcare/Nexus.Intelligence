using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

/// <summary>
/// Derives the governed path's inputs from a Product's turn envelope.
/// </summary>
/// <remarks>
/// <para>
/// <b>One derivation, used by every path that can reach a model.</b> The turn envelope predates the
/// exposure model: it carries a tenant, a product, a scope and an actor, and it carries no
/// classification, no requester identity and no execution policy. The governed path needs all three. If
/// each entry point derived them for itself, an estate would have two answers to "how sensitive is a
/// turn that declared nothing" — and the divergence would appear as one endpoint that refuses what the
/// other permits, with no line of code stating which is intended.
/// </para>
/// <para>
/// <b>Every substitution is recorded rather than applied silently.</b> A defaulted classification is a
/// fact an auditor needs to distinguish from a declared one, so the derivation writes a
/// <see cref="DecisionTrace"/> when it substitutes and nothing when the caller spoke. That is why these
/// are methods taking the decision list rather than properties returning values.
/// </para>
/// </remarks>
internal static class TurnEnvelope
{
    /// <summary>The classification a turn runs under when its caller declared none.</summary>
    /// <remarks>
    /// <see cref="DataClassification.Internal"/>, because a turn about the estate's own work is what an
    /// unclassified turn is in practice, and it is the conservative reading: it is above
    /// <see cref="DataClassification.Public"/> and below every category that carries a redaction
    /// requirement. A caller that says nothing therefore gets a stricter posture than one that says
    /// <c>Public</c>, which is the right direction for an omission to fail in.
    /// </remarks>
    private const DataClassification DefaultedClassification = DataClassification.Internal;

    /// <summary>
    /// The turn's classification, from the envelope where stated and from a recorded default where not.
    /// </summary>
    /// <remarks>
    /// The default is not the hole it would be elsewhere. The registry is fail-closed — no model and no
    /// provider is approved in a default estate, so no turn reaches a provider until an operator has
    /// recorded a ceiling covering this classification. The default decides which turns an operator must
    /// have thought about, not whether a turn escapes review.
    /// </remarks>
    internal static DataClassification Classify(
        IntelligenceTurnRequest request,
        List<DecisionTrace> decisions)
    {
        if (request.Classification is { } declared)
        {
            decisions.Add(new DecisionTrace(
                $"Classified the turn as '{declared}'",
                "Declared by the caller on the turn envelope.",
                []));

            return declared;
        }

        decisions.Add(new DecisionTrace(
            $"Classified the turn as '{DefaultedClassification}'",
            "The caller declared no classification, so the pipeline supplied the conservative default for a "
            + "turn about the estate's own work. A defaulted classification is recorded rather than silent, "
            + "so an auditor can tell this turn from one that was deliberately classified.",
            []));

        return DefaultedClassification;
    }

    /// <summary>
    /// The requester identity, derived from the turn envelope.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Nothing here is invented. The head is <see cref="CallingHead.Product"/> because the turn envelope is
    /// a Product's contract; the workspace is the envelope's own scope key; and the data scope is that
    /// same coordinate written back in the <c>kind:key</c> form the exposure policy compares against.
    /// </para>
    /// <para>
    /// <b>The data scope must be declared or the context gate fires.</b> The governance engine refuses a
    /// turn whose context ceiling is above Public and whose requester declared no scope, as
    /// <see cref="AiGovernanceRules.ContextScopeUndeclared"/>. Deriving the scope from the envelope is
    /// what makes that refusal meaningful: it fires when the <em>context</em> is unscoped, not when the
    /// envelope happens to be missing a field this layer could have filled.
    /// </para>
    /// </remarks>
    internal static AiRequesterIdentity RequesterFor(IntelligenceTurnRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        return new AiRequesterIdentity
        {
            Head = CallingHead.Product,
            ProductId = request.ProductId,
            TenantId = request.TenantId,

            // ScopeRef.Key rather than Path: the key is the coordinate the product considers itself
            // scoped to, and a path is a route to it rather than a name for it.
            WorkspaceId = request.Scope.Key,
            PrincipalId = request.Actor.UserId,
            PermissionScope = new AiPermissionScope
            {
                Permissions = request.Actor.Permissions,

                // Reaching a side-effecting tool requires the same wildcard the policy gate requires.
                // Both must permit, and the narrower of the two decides.
                MayCauseSideEffects = request.Actor.Permissions.Contains(PolicyGate.ToolWildcard),
                RequiresHumanApprovalForSideEffects = request.Constraints.RequireApprovalForWrites,
            },
            DataScopes = [$"{request.Scope.Kind}:{request.Scope.Key}"],
        };
    }

    /// <summary>The execution policy, derived from the turn's constraints.</summary>
    /// <remarks>
    /// The quality requirement is <see cref="AiQualityRequirement.Complete"/> — a turn must produce an
    /// answer — and the degradation preference is
    /// <see cref="AiDegradationPreference.ReturnDeterministicResult"/>, the honest posture for a
    /// conversational product: a Chat surface with no model available should say so in its own words
    /// rather than fail the operation. Both are stated rather than defaulted so that a later lane changing
    /// them changes a line with a reason attached.
    /// </remarks>
    internal static AiExecutionPolicy ExecutionFor(TurnConstraints constraints)
    {
        ArgumentNullException.ThrowIfNull(constraints);

        return new AiExecutionPolicy
        {
            LatencyBudget = constraints.LatencyBudget,
            MaxCost = constraints.MaxCost,
            Quality = AiQualityRequirement.Complete,
            OnDegradation = AiDegradationPreference.ReturnDeterministicResult,
        };
    }

    /// <summary>A caller-facing statement of what the turn was for.</summary>
    internal static string PurposeFor(TurnIntent intent) => intent switch
    {
        TurnIntent.Question => "Answer a question about the product's own content.",
        TurnIntent.Task => "Carry out a task the actor described.",
        TurnIntent.Planning => "Produce a plan the actor can act on.",
        TurnIntent.Approval => "Assess something the actor asked to have reviewed.",
        TurnIntent.Event => "Respond to an event the product raised.",
        TurnIntent.Unclear => "Respond to a request whose purpose the classifier could not determine.",
        _ => throw new ArgumentOutOfRangeException(nameof(intent), intent, null),
    };
}
