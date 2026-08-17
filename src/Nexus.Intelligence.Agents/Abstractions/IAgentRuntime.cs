namespace NexusAI.Core.Agents;

public interface IAgentRuntime
{
    Task RunAsync(
        IAgent agent,
        AgentContext context,
        CancellationToken cancellationToken = default);
}