using Nexus.Intelligence.Agents.Abstractions;
using Nexus.Intelligence.Core.Turns;

namespace Nexus.Intelligence.Core.Execution;

public sealed class ExecutionEngine : IExecutionEngine
{
    private readonly IAgentSelector _agentSelector;
    private readonly IAgentDispatcher _dispatcher;

    public ExecutionEngine(IAgentSelector agentSelector, IAgentDispatcher dispatcher)
    {
        _agentSelector = agentSelector;
        _dispatcher = dispatcher;
    }

    public async Task<ExecutionResult> ExecuteAsync(ExecutionContext context, CancellationToken cancellationToken = default)
    {
        var selection = _agentSelector.Select(TurnIntent.Task, context.Actor);

        var agentContext = new AgentContext(context.Scope, context.Actor, selection.Type);

        var agentResult = await _dispatcher.DispatchAsync(agentContext, cancellationToken);

        return new ExecutionResult(agentResult.Success, agentResult.Success ? 1 : 0);
    }
}
