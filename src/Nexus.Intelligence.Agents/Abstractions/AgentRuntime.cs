using NexusAI.Core.Agents;

namespace NexusAI.Infrastructure.Agents;

public sealed class AgentRuntime : IAgentRuntime
{
    public Task RunAsync(
        IAgent agent,
        AgentContext context,
        CancellationToken cancellationToken = default)
    {
        return agent.ExecuteAsync(
            context,
            cancellationToken);
    }
}