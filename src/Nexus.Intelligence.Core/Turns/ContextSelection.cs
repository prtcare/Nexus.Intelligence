using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public sealed record ContextSelection(IReadOnlyList<RankedContextItem> Ranked, DecisionTrace Decision);
