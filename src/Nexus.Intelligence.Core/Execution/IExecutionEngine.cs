namespace Nexus.Intelligence.Core.Execution;

public interface IExecutionEngine
{
    Task<ExecutionResult> ExecuteAsync(ExecutionContext context, CancellationToken cancellationToken = default);
}
