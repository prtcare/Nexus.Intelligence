using NexusAI.Core.Agents;

namespace NexusAI.Application.Execution;

public sealed class ExecutionEngine : IExecutionEngine
{
    private readonly IAgentDispatcher _dispatcher;

    public ExecutionEngine(IAgentDispatcher dispatcher)
    {
        _dispatcher = dispatcher;
    }

    public async Task<ExecutionResult> ExecuteAsync(
        ExecutionContext context,
        CancellationToken cancellationToken = default)
    {
        var agentContext = new AgentContext(
            context.ProjectId.ToString(),
            string.Empty,
            string.Empty,
            AgentType.Developer);

        var agentResult = await _dispatcher.DispatchAsync(
            agentContext,
            cancellationToken);

        return new ExecutionResult(
            agentResult.Success,
            agentResult.Success ? 1 : 0);
    }
}