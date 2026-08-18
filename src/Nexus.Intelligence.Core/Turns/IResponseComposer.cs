using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Turns;

public interface IResponseComposer
{
    ComposedResponse Compose(
        string turnId,
        ModelInvocationResult modelResult,
        IReadOnlyList<RankedContextItem> rankedContext,
        IReadOnlyList<ProposedAction> proposedActions,
        UsageSummary usage);
}
