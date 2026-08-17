using NexusAI.Core.Agents;

namespace NexusAI.Agents.Developer;

public sealed class DeveloperAgent : IAgent
{
    public AgentMetadata Metadata => new()
    {
        Id = "developer",
        Name = "Developer",
        Description = "Software development assistant"
    };

    public Task<AgentResult> ExecuteAsync(
        AgentContext context,
        CancellationToken cancellationToken = default)
    {
        Console.WriteLine($"Running {Metadata.Name} Agent");
        Console.WriteLine($"Project: {context.ProjectId}");

        return Task.FromResult(
            new AgentResult(
                true,
                "Developer agent execution completed."));
    }
}