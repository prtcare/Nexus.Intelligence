using Nexus.Intelligence.Agents.Abstractions;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public interface IAgentSelector
{
    AgentSelection Select(TurnIntent intent, ActorRef actor);
}
