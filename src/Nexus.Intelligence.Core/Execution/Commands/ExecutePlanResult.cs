namespace NexusAI.Application.Execution.Commands;

public sealed record ExecutePlanResult(
    bool Success,
    int ExecutedWorkItems);