namespace Nexus.Intelligence.Agents.Abstractions;

public interface IAgentRegistry
{
    IReadOnlyCollection<IAgent> GetAll();

    IAgent GetAgent(AgentType type);

    bool TryGetAgent(
        AgentType type,
        out IAgent? agent);
}
