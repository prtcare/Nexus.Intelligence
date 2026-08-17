using NexusAI.Core.Agents;

namespace NexusAI.Application.Execution;

public interface IAgentDispatcher
{
    Task<AgentResult> DispatchAsync(
        AgentContext context,
        CancellationToken cancellationToken = default);
}