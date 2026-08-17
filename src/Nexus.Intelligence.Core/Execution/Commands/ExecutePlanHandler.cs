using NexusAI.Application.Execution;

namespace NexusAI.Application.Execution.Commands;

public sealed class ExecutePlanHandler
{
    private readonly IExecutionEngine _executionEngine;

    public ExecutePlanHandler(
        IExecutionEngine executionEngine)
    {
        _executionEngine = executionEngine;
    }

    public async Task<ExecutePlanResult> HandleAsync(
        ExecutePlanCommand command,
        CancellationToken cancellationToken = default)
    {
        var context = new ExecutionContext(
    command.ProjectId);

        var result =
            await _executionEngine.ExecuteAsync(
                context,
                cancellationToken);

        return new ExecutePlanResult(
            result.Success,
            result.ExecutedWorkItems);
    }
}