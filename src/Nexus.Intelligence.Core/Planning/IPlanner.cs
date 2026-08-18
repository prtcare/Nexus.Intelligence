using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Planning;

public interface IPlanner
{
    Task<PlanPayload> CreatePlanAsync(IntelligenceTurnRequest request, CancellationToken ct = default);
}
