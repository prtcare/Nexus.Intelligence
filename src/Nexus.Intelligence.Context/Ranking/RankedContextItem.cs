using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Context.Ranking;

public sealed record RankedContextItem(ContextItem Item, double Score);
