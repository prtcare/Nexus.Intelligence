namespace NexusAI.Core.Agents;

public interface IAgentRegistry
{
    IReadOnlyCollection<IAgent> GetAll();

    IAgent GetAgent(AgentType type);

    bool TryGetAgent(
        AgentType type,
        out IAgent? agent);
}