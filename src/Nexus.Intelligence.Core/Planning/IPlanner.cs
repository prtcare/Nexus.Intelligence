using NexusAI.Domain.Project;
using WorkItemModel = NexusAI.Domain.WorkItem.WorkItem;

namespace NexusAI.Application.Planning;

public interface IPlanner
{
    Task<IReadOnlyList<WorkItemModel>> CreatePlanAsync(
        ProjectId projectId,
        string objective,
        CancellationToken cancellationToken = default);
}