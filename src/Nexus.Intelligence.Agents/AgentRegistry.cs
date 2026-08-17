using NexusAI.Core.Agents;

namespace NexusAI.Infrastructure.Services;

public sealed class AgentRegistry : IAgentRegistry
{
    private readonly IReadOnlyDictionary<AgentType, IAgent> _agents;

    public AgentRegistry(IEnumerable<IAgent> agents)
    {
        ArgumentNullException.ThrowIfNull(agents);

        var registrations = new Dictionary<AgentType, IAgent>();

        foreach (var agent in agents)
        {
            var type = ResolveType(agent);

            if (!registrations.TryAdd(type, agent))
            {
                throw new InvalidOperationException(
                    $"Multiple agents are registered for '{type}'.");
            }
        }

        _agents = registrations;
    }

    public IReadOnlyCollection<IAgent> GetAll()
    {
        return _agents.Values.ToArray();
    }

    public IAgent GetAgent(AgentType type)
    {
        if (_agents.TryGetValue(type, out var agent))
        {
            return agent;
        }

        throw new InvalidOperationException(
            $"No agent registered for '{type}'.");
    }

    public bool TryGetAgent(
        AgentType type,
        out IAgent? agent)
    {
        return _agents.TryGetValue(type, out agent);
    }

    private static AgentType ResolveType(IAgent agent)
    {
        ArgumentNullException.ThrowIfNull(agent);

        return agent.Metadata.Id.Trim().ToLowerInvariant() switch
        {
            "developer" => AgentType.Developer,
            "reviewer" => AgentType.Reviewer,
            "architect" => AgentType.Architect,
            "research" => AgentType.Research,
            "test" => AgentType.Test,

            _ => throw new InvalidOperationException(
                $"Agent '{agent.Metadata.Id}' is not mapped to an AgentType.")
        };
    }
}