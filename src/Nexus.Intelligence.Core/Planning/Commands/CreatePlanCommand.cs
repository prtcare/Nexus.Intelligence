using NexusAI.Domain.Project;

namespace NexusAI.Application.Planning.Commands;

public sealed record CreatePlanCommand(
    ProjectId ProjectId,
    string Objective);