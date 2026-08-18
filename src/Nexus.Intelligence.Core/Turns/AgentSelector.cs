using Nexus.Intelligence.Agents.Abstractions;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public sealed class AgentSelector : IAgentSelector
{
    private const string AgentWildcard = "agents:*";

    private readonly IAgentRegistry _registry;

    public AgentSelector(IAgentRegistry registry)
    {
        _registry = registry;
    }

    public AgentSelection Select(TurnIntent intent, ActorRef actor)
    {
        var preferred = PreferredType(intent);
        var developer = _registry.GetAgent(AgentType.Developer);

        if (preferred == AgentType.Developer)
        {
            return new AgentSelection(
                developer,
                AgentType.Developer,
                new DecisionTrace(
                    $"Selected '{developer.Metadata.Name}' agent",
                    $"Intent '{intent}' maps directly to the Developer agent",
                    []));
        }

        // Convention: "agents:*" or "agent:<type>" (lowercase) authorizes a non-Developer agent type.
        var authorized = actor.Permissions.Contains(AgentWildcard) ||
                          actor.Permissions.Contains($"agent:{preferred.ToString().ToLowerInvariant()}");

        if (authorized && _registry.TryGetAgent(preferred, out var agent) && agent is not null)
        {
            return new AgentSelection(
                agent,
                preferred,
                new DecisionTrace(
                    $"Selected '{agent.Metadata.Name}' agent",
                    $"Intent '{intent}' maps to agent type '{preferred}' and the actor is authorized",
                    [nameof(AgentType.Developer)]));
        }

        var reason = !authorized
            ? $"Actor lacks permission for agent type '{preferred}'"
            : $"No agent registered for '{preferred}'";

        return new AgentSelection(
            developer,
            AgentType.Developer,
            new DecisionTrace(
                $"Selected '{developer.Metadata.Name}' agent (fallback)",
                $"{reason}; Developer is the default fallback",
                [preferred.ToString()]));
    }

    private static AgentType PreferredType(TurnIntent intent) => intent switch
    {
        TurnIntent.Question => AgentType.Research,
        TurnIntent.Task => AgentType.Developer,
        TurnIntent.Planning => AgentType.Architect,
        TurnIntent.Approval => AgentType.Reviewer,
        TurnIntent.Event => AgentType.Developer,
        TurnIntent.Unclear => AgentType.Developer,
        _ => throw new ArgumentOutOfRangeException(nameof(intent), intent, null)
    };
}
