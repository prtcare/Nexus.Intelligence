using Nexus.Intelligence.Agents.Abstractions;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public sealed record AgentSelection(IAgent Agent, AgentType Type, DecisionTrace Decision);
