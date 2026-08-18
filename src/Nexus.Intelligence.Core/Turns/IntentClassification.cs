using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public sealed record IntentClassification(TurnIntent Intent, DecisionTrace Decision);
