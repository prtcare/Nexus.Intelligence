using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Turns;

public sealed record ModelSelection(ModelDescriptor Model, DecisionTrace Decision);
