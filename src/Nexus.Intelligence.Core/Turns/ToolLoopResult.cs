using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Turns;

public sealed record ToolLoopResult(
    ModelInvocationResult FinalResult,
    IReadOnlyList<ProposedAction> ProposedActions,
    ModelUsage AccumulatedUsage,
    IReadOnlyList<DecisionTrace> Decisions);
