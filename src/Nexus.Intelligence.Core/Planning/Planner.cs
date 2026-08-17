using NexusAI.Domain.Project;
using NexusAI.Domain.WorkItem;
using WorkItemModel = NexusAI.Domain.WorkItem.WorkItem;

namespace NexusAI.Application.Planning;

public sealed class Planner : IPlanner
{
    public Task<IReadOnlyList<WorkItemModel>> CreatePlanAsync(
        ProjectId projectId,
        string objective,
        CancellationToken cancellationToken = default)
    {
        var items = new List<WorkItemModel>
        {
            new(
                WorkItemId.New(),
                projectId,
                $"Analyze: {objective}",
                WorkItemType.Research,
                DateTimeOffset.UtcNow),

            new(
                WorkItemId.New(),
                projectId,
                "Design Solution",
                WorkItemType.Spike,
                DateTimeOffset.UtcNow),

            new(
                WorkItemId.New(),
                projectId,
                "Implement",
                WorkItemType.Feature,
                DateTimeOffset.UtcNow),

            new(
                WorkItemId.New(),
                projectId,
                "Validate",
                WorkItemType.Task,
                DateTimeOffset.UtcNow)
        };

        return Task.FromResult<IReadOnlyList<WorkItemModel>>(items);
    }
}