using NexusAI.Domain.Project;

namespace NexusAI.Application.Execution;

public sealed record ExecutionContext(
    ProjectId ProjectId);