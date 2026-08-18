using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public interface ITurnPipeline
{
    Task<IntelligenceTurnResponse> ExecuteAsync(IntelligenceTurnRequest request, CancellationToken ct = default);
}
