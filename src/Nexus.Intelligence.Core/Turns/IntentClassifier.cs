using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public sealed class IntentClassifier : IIntentClassifier
{
    private static readonly string[] QuestionStarters =
        ["what", "why", "how", "when", "where", "who", "which", "can", "could", "should", "is", "are", "does", "do"];

    private static readonly string[] PlanningKeywords =
        ["plan", "roadmap", "break down", "break this down", "steps to", "milestones", "decompose"];

    private static readonly string[] TaskVerbs =
        ["add", "fix", "build", "implement", "create", "update", "refactor", "remove", "delete", "write", "rename", "migrate", "deploy"];

    public IntentClassification Classify(TurnInput input)
    {
        var intent = input.Kind switch
        {
            TurnInputKind.Approval => TurnIntent.Approval,
            TurnInputKind.Event => TurnIntent.Event,
            TurnInputKind.Task => TurnIntent.Task,
            TurnInputKind.UserMessage => ClassifyMessage(input.Text),
            _ => TurnIntent.Unclear
        };

        var why = input.Kind == TurnInputKind.UserMessage
            ? "Free-text message classified by question/planning/task heuristics"
            : $"Input kind '{input.Kind}' maps directly to this intent";

        var alternatives = Enum.GetValues<TurnIntent>()
            .Where(candidate => candidate != intent)
            .Select(candidate => candidate.ToString())
            .ToArray();

        return new IntentClassification(intent, new DecisionTrace($"Classified turn intent as '{intent}'", why, alternatives));
    }

    private static TurnIntent ClassifyMessage(string text)
    {
        var trimmed = text.Trim();

        if (trimmed.Length == 0)
        {
            return TurnIntent.Unclear;
        }

        if (trimmed.EndsWith('?') || QuestionStarters.Any(word => StartsWithWord(trimmed, word)))
        {
            return TurnIntent.Question;
        }

        if (PlanningKeywords.Any(word => trimmed.Contains(word, StringComparison.OrdinalIgnoreCase)))
        {
            return TurnIntent.Planning;
        }

        if (TaskVerbs.Any(word => StartsWithWord(trimmed, word)))
        {
            return TurnIntent.Task;
        }

        return TurnIntent.Unclear;
    }

    private static bool StartsWithWord(string text, string word)
    {
        if (!text.StartsWith(word, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return text.Length == word.Length || !char.IsLetterOrDigit(text[word.Length]);
    }
}
