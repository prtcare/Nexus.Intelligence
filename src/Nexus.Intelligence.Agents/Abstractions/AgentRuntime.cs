namespace Nexus.Intelligence.Agents.Abstractions;

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
