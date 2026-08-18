using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Turns;

public sealed record ModelStepResult(ModelInvocationResult Result, DecisionTrace Decision);
