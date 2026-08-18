using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public interface IPolicyGate
{
    PolicyGateResult Evaluate(ActorRef actor, TurnConstraints constraints);
}
