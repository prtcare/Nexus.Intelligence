using NexusAI.Domain.Project;

namespace NexusAI.Application.Execution;

public interface IExecutionEngine
{
    Task<ExecutionResult> ExecuteAsync(
    ExecutionContext context,
    CancellationToken cancellationToken = default);
}