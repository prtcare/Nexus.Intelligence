namespace NexusAI.Application.Execution;

public sealed record ExecutionResult(
    bool Success,
    int ExecutedWorkItems);