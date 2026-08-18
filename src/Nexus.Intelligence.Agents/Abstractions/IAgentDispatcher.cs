namespace Nexus.Intelligence.Agents.Abstractions;

public interface IAgentDispatcher
{
    Task<AgentResult> DispatchAsync(
        AgentContext context,
        CancellationToken cancellationToken = default);
}
