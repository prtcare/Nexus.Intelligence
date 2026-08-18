using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public sealed record ComposedResponse(IntelligenceTurnResponse Response, DecisionTrace Decision);
