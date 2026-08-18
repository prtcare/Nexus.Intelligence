using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Turns;

public interface IModelSelector
{
    Task<ModelSelection> SelectAsync(TurnIntent intent, TurnConstraints constraints, CancellationToken ct = default);
}
