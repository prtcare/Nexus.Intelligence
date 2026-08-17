using NexusAI.Domain.Project;

namespace NexusAI.Application.Execution.Commands;

public sealed record ExecutePlanCommand(
    ProjectId ProjectId);