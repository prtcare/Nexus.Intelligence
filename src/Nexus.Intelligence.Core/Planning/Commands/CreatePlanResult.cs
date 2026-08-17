using NexusAI.Domain.WorkItem;
using WorkItemModel = NexusAI.Domain.WorkItem.WorkItem;

namespace NexusAI.Application.Planning.Commands;

public sealed record CreatePlanResult(
    IReadOnlyList<WorkItemModel> WorkItems);