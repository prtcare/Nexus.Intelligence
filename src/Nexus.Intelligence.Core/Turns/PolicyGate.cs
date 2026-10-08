using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public sealed class PolicyGate : IPolicyGate
{
    /// <summary>
    /// The permission key that grants a caller every tool the pipeline offers.
    /// </summary>
    /// <remarks>
    /// Internal rather than private because <see cref="TurnEnvelope"/> derives the governed requester's
    /// side-effect permission from the same key this gate reads. Two spellings of one key would let a
    /// caller pass the platform gate and fail the governed one — or worse, pass both while the estate
    /// believed only one was in use.
    /// </remarks>
    internal const string ToolWildcard = "tools:*";

    public PolicyGateResult Evaluate(ActorRef actor, TurnConstraints constraints)
    {
        if (actor.Permissions.Count == 0)
        {
            var denied = new PolicyVerdict
            {
                Allowed = false,
                AllowedTools = [],
                RequireApprovalForWrites = constraints.RequireApprovalForWrites,
                DenialReason = "Actor has no granted permissions."
            };

            return new PolicyGateResult(
                denied,
                new DecisionTrace("Denied the turn", "Actor holds zero permissions", ["allow with empty tool set"]));
        }

        var hasWildcard = actor.Permissions.Contains(ToolWildcard);

        // Convention: a permission string equal to a tool id grants that tool; "tools:*" grants every constraint-listed tool.
        var allowedTools = hasWildcard
            ? constraints.AllowedTools
            : constraints.AllowedTools.Where(actor.Permissions.Contains).ToArray();

        var verdict = new PolicyVerdict
        {
            Allowed = true,
            AllowedTools = allowedTools,
            RequireApprovalForWrites = constraints.RequireApprovalForWrites
        };

        var why = hasWildcard
            ? "Actor holds 'tools:*'; every constraint-listed tool is permitted"
            : $"Permitted tools intersected with actor permissions: {allowedTools.Count} of {constraints.AllowedTools.Count} constraint-listed tools allowed";

        return new PolicyGateResult(
            verdict,
            new DecisionTrace("Allowed the turn with a scoped tool set", why, ["deny (no permissions)"]));
    }
}
