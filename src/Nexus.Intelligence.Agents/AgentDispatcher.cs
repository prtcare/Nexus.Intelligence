using NexusAI.Application.Execution;
using NexusAI.Core.Agents;

namespace NexusAI.Infrastructure.Services;

public sealed class AgentDispatcher : IAgentDispatcher
{
    private readonly IAgentRegistry _registry;

    public AgentDispatcher(IAgentRegistry registry)
    {
        _registry = registry;
    }

    public Task<AgentResult> DispatchAsync(
        AgentContext context,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);

        var agent = _registry.GetAgent(context.AgentType);

        return agent.ExecuteAsync(
            context,
            cancellationToken);
    }
}