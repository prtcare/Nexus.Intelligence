using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public interface IIntentClassifier
{
    IntentClassification Classify(TurnInput input);
}
