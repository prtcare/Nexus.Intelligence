using Microsoft.Extensions.Logging;
using Nexus.Intelligence.Agents.Abstractions;

namespace Nexus.Intelligence.Agents.BuiltIn;

public sealed class DeveloperAgent : IAgent
{
    private readonly ILogger<DeveloperAgent> _logger;

    public DeveloperAgent(ILogger<DeveloperAgent> logger)
    {
        _logger = logger;
    }

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
        _logger.LogInformation(
            "Running {AgentName} agent for scope {ScopeKind}:{ScopeKey}",
            Metadata.Name,
            context.Scope.Kind,
            context.Scope.Key);

        return Task.FromResult(
            new AgentResult(
                true,
                "Developer agent execution completed."));
    }
}
