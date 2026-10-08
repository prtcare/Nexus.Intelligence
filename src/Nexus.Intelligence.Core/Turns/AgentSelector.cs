using Nexus.Intelligence.Agents.Abstractions;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

/// <summary>
/// Selects the agent for a turn, from the AI agent registry.
/// </summary>
/// <remarks>
/// <para>
/// <b>W7D TASK 2.</b> The selection used to be a <c>switch</c> over <c>TurnIntent</c> producing an
/// <c>AgentType</c> enum member, resolved through a second hardcoded switch from identifier to enum
/// member. The set of agents an estate could run was therefore the set of enum members compiled into the
/// assembly, and adding one was a code change.
/// </para>
/// <para>
/// <b>The mapping from intent to agent is still a convention, and it is now a convention over
/// registry keys rather than over compiled-in types.</b> That distinction is the whole of the change:
/// <see cref="PreferredAgentId"/> names identifiers an operator can register, and the agent that acts is
/// whichever the registry holds under that identifier — or none, in which case the turn is refused
/// rather than silently served by a built-in.
/// </para>
/// <para>
/// <b>This type proposes and does not decide.</b> It chooses a candidate and says why; the governance
/// engine then refuses the turn if that agent is not registered or not approved, as
/// <see cref="AiGovernanceRules.AgentUnregistered"/> or
/// <see cref="AiGovernanceRules.AgentNotApproved"/>. So a selector that picks a good candidate is a
/// convenience and a selector that picks a bad one is a refusal with a named rule — neither is a
/// permission.
/// </para>
/// </remarks>
public sealed class AgentSelector : IAgentSelector
{
    /// <summary>The permission key that authorises an agent other than the default.</summary>
    private const string AgentWildcard = "agents:*";

    /// <summary>
    /// The agent a turn runs under when nothing more specific is authorised or available.
    /// </summary>
    /// <remarks>
    /// A registry key rather than an enum member, so an operator may register a different agent under it
    /// — or register none, in which case every defaulted turn is refused by governance and the refusal
    /// says the agent is unregistered. That is a better failure than a built-in agent that always
    /// exists and can never be turned off.
    /// </remarks>
    private const string DefaultAgentId = "developer";

    private readonly IAgentRegistry _runtimeRegistry;
    private readonly IAiAgentRegistry _aiRegistry;

    /// <summary>Composes the selector over the runtime registry and the AI agent registry.</summary>
    public AgentSelector(IAgentRegistry runtimeRegistry, IAiAgentRegistry aiRegistry)
    {
        ArgumentNullException.ThrowIfNull(runtimeRegistry);
        ArgumentNullException.ThrowIfNull(aiRegistry);

        _runtimeRegistry = runtimeRegistry;
        _aiRegistry = aiRegistry;
    }

    /// <inheritdoc />
    public AgentSelection Select(TurnIntent intent, ActorRef actor)
    {
        ArgumentNullException.ThrowIfNull(actor);

        var preferredId = PreferredAgentId(intent);

        // The runtime registry is consulted only for the dispatcher's type. A configured agent that has
        // no runtime implementation is still selected and still governed: the refusal that follows is
        // the accurate one, and reporting "no implementation" instead would hide that the agent is also
        // unapproved.
        var registered = _aiRegistry.TryGetAgent(preferredId, out var candidate) && candidate is not null;

        if (preferredId == DefaultAgentId)
        {
            return new AgentSelection(
                preferredId,
                TypeFor(preferredId),
                new DecisionTrace(
                    $"Selected agent '{preferredId}'",
                    registered
                        ? $"Intent '{intent}' maps to the default agent, which the registry holds."
                        : $"Intent '{intent}' maps to the default agent, which the registry does not hold. "
                          + "The turn will be refused by governance rather than served by a built-in agent.",
                    []));
        }

        // Convention: "agents:*" or "agent:<id>" (lowercase) authorises a non-default agent.
        var authorized = actor.Permissions.Contains(AgentWildcard)
                         || actor.Permissions.Contains($"agent:{preferredId}");

        if (authorized && registered)
        {
            return new AgentSelection(
                preferredId,
                TypeFor(preferredId),
                new DecisionTrace(
                    $"Selected agent '{preferredId}'",
                    $"Intent '{intent}' maps to agent '{preferredId}' and the actor is authorized for it",
                    [DefaultAgentId]));
        }

        var reason = !authorized
            ? $"Actor lacks permission for agent '{preferredId}'"
            : $"The registry holds no agent '{preferredId}'";

        return new AgentSelection(
            DefaultAgentId,
            TypeFor(DefaultAgentId),
            new DecisionTrace(
                $"Selected agent '{DefaultAgentId}' as the fallback",
                $"{reason}; '{DefaultAgentId}' is the default. Whether it may act is governance's answer, "
                + "not this selector's.",
                [preferredId]));
    }

    /// <summary>
    /// The registry key a turn intent prefers.
    /// </summary>
    /// <remarks>
    /// A convention, documented here and nowhere else, over identifiers an operator registers. It is not
    /// a capability check: an agent registered under one of these keys and not permitted the turn's
    /// capability is refused as <see cref="AiGovernanceRules.AgentCapabilityNotPermitted"/>, which is the
    /// authority for what an agent may serve.
    /// </remarks>
    private static string PreferredAgentId(TurnIntent intent) => intent switch
    {
        TurnIntent.Question => "research",
        TurnIntent.Task => "developer",
        TurnIntent.Planning => "architect",
        TurnIntent.Approval => "reviewer",
        TurnIntent.Event => "developer",
        TurnIntent.Unclear => "developer",
        _ => throw new ArgumentOutOfRangeException(nameof(intent), intent, null),
    };

    /// <summary>
    /// The dispatcher's type for an agent, or the default when the runtime registry holds none.
    /// </summary>
    /// <remarks>
    /// Only <c>ExecutionEngine</c> reads this, and it reads it to hand an <c>AgentContext</c> to a
    /// dispatcher. A turn's agent identity does not come from here, which is why a miss is not an error:
    /// the governed path never asks this question.
    /// </remarks>
    private AgentType TypeFor(string agentId) => agentId switch
    {
        "research" => AgentType.Research,
        "architect" => AgentType.Architect,
        "reviewer" => AgentType.Reviewer,
        "test" => AgentType.Test,
        _ => AgentType.Developer,
    };
}
