namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The authoritative statement of which models exist and what they can do.
/// </summary>
/// <remarks>
/// <para>
/// <b>Membership and capability live here, and nowhere in code.</b> The directive's rule that the
/// permanent model list must not be hardcoded into router code is satisfied structurally rather than
/// by discipline: the router holds no model identifier and no provider identifier, it holds this
/// interface, and every identifier it ever sees came out of an implementation of it. There is no
/// <c>if (modelId == "...")</c> the router could contain, because the router is never handed a
/// literal to compare against.
/// </para>
/// <para>
/// <b>The only listing is capability-scoped.</b> Routing has exactly one question — "what can serve
/// this capability?" — and that is the only enumeration this port offers. A full listing is
/// deliberately absent for the reason <see cref="IAiGovernanceRegister"/> gives for having no
/// enumeration at all: a registry that can be asked to materialise everything it holds will
/// eventually be asked on a hot path, and an inventory that scales with the estate is not something a
/// request should build. An operator surface that needs the whole list is a different concern, and
/// belongs to the lane that owns operator surfaces.
/// </para>
/// </remarks>
public interface IAiModelRegistry
{
    /// <summary>
    /// Every model whose registration claims the capability, in a stable, deterministic order.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>The order is part of the contract.</b> Ranking is deterministic and the tie-breakers are
    /// explicit, but a caller that seeds a ranking from a non-deterministic order has made the whole
    /// outcome non-deterministic through a tie-break nobody wrote down. An implementation must
    /// therefore return the same order for the same registry state, and the natural choice — ordinal
    /// by model identifier — is the one W7C's implementation makes.
    /// </para>
    /// <para>
    /// Claiming a capability is not a promise it can be routed to. The models returned are candidates
    /// for the router's filters, not selections: a model disabled, unhealthy, unapproved or outside
    /// the caller's cost ceiling is still returned here and removed by the filter whose reason it is.
    /// Filtering in this method instead would collapse every distinct refusal into "returned nothing",
    /// and a caller asking why its work did not run would get no answer.
    /// </para>
    /// </remarks>
    IReadOnlyList<AiModelRegistration> ListForCapability(CapabilityId capability);

    /// <summary>Resolves one model by its identifier. False when nothing is registered under it.</summary>
    /// <remarks>
    /// False is a refusal and not a miss. An unresolvable model is one the governance register will
    /// also fail to resolve, so the execution is blocked with
    /// <see cref="AiGovernanceRules.ModelUnregistered"/> rather than silently rerouted — which is the
    /// direction the directive requires when a caller-named or configuration-named model does not exist.
    /// </remarks>
    bool TryGetModel(string? modelId, out AiModelRegistration? registration);

    /// <summary>How many models the registry holds. A count, for diagnostics — not a capability.</summary>
    int Count { get; }
}
