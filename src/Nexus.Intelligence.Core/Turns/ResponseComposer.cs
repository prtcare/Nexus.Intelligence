using System.Text.RegularExpressions;
using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Turns;

public sealed partial class ResponseComposer : IResponseComposer
{
    public ComposedResponse Compose(
        string turnId,
        ModelInvocationResult modelResult,
        IReadOnlyList<RankedContextItem> rankedContext,
        IReadOnlyList<ProposedAction> proposedActions,
        UsageSummary usage)
    {
        var contextIds = rankedContext.Select(r => r.Item.Id).ToHashSet();
        var content = modelResult.Message?.Content ?? string.Empty;

        var citations = CitationPattern().Matches(content)
            .Select(m => m.Groups["id"].Value)
            .Distinct()
            .Where(contextIds.Contains)
            .Select(id => new Citation(id, null))
            .ToList();

        var persistenceHints = proposedActions
            .Select(action => new PersistenceHint(
                PersistenceHintKind.ActionCandidate,
                $"Proposed action: {action.ToolRef}",
                action.Rationale ?? $"Tool '{action.ToolRef}' requested with {action.Arguments.Count} argument(s).",
                TrustLevel.Reported))
            .ToList();

        var outcome = !modelResult.Success
            ? TurnOutcomeKind.Failed
            : proposedActions.Count > 0
                ? TurnOutcomeKind.Actions
                : TurnOutcomeKind.Reply;

        IReadOnlyList<TurnError> errors = modelResult.Success
            ? []
            : [new TurnError("model_invocation_failed", modelResult.Error ?? "The model gateway did not return a result.", null)];

        var response = new IntelligenceTurnResponse
        {
            TurnId = turnId,
            Outcome = outcome,
            Reply = modelResult.Success ? new ReplyPayload(content, ReplyFormat.Markdown) : null,
            Actions = proposedActions,
            Citations = citations,
            PersistenceHints = persistenceHints,
            Usage = usage,
            Errors = errors
        };

        var alternatives = Enum.GetValues<TurnOutcomeKind>()
            .Where(candidate => candidate != outcome)
            .Select(candidate => candidate.ToString())
            .ToArray();

        var decision = new DecisionTrace(
            $"Composed response with outcome '{outcome}'",
            $"{citations.Count} citation(s) resolved, {proposedActions.Count} action(s) proposed, model success = {modelResult.Success}",
            alternatives);

        return new ComposedResponse(response, decision);
    }

    // Mirrors the [ctx:<id>] marker PromptAssembler embeds in the prompt; the model echoes it back to cite a source.
    [GeneratedRegex(@"\[ctx:(?<id>[^\]]+)\]")]
    private static partial Regex CitationPattern();
}
