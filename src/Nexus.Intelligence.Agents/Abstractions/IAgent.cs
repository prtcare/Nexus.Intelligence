namespace Nexus.Intelligence.Agents.Abstractions;

public interface IAgent
{
    AgentMetadata Metadata { get; }

    Task<AgentResult> ExecuteAsync(
        AgentContext context,
        CancellationToken cancellationToken = default);
}
