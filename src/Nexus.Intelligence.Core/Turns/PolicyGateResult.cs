using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public sealed record PolicyGateResult(PolicyVerdict Verdict, DecisionTrace Decision);
