using NexusAI.Domain.WorkItem;
using NexusAI.Application.Planning;

namespace NexusAI.Application.Planning.Commands;

public sealed class CreatePlanHandler
{
    private readonly IPlanner _planner;
    private readonly IWorkItemRepository _repository;

    public CreatePlanHandler(
        IPlanner planner,
        IWorkItemRepository repository)
    {
        _planner = planner;
        _repository = repository;
    }

    public async Task<CreatePlanResult> HandleAsync(
        CreatePlanCommand command,
        CancellationToken cancellationToken = default)
    {
        var workItems =
            await _planner.CreatePlanAsync(
                command.ProjectId,
                command.Objective,
                cancellationToken);

        foreach (var item in workItems)
        {
            await _repository.AddAsync(
                item,
                cancellationToken);
        }

        return new CreatePlanResult(workItems);
    }
}