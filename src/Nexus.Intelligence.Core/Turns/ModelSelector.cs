using System.Text;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Turns;

public sealed class ModelSelector : IModelSelector
{
    private readonly IModelCatalog _catalog;

    public ModelSelector(IModelCatalog catalog)
    {
        _catalog = catalog;
    }

    public async Task<ModelSelection> SelectAsync(TurnIntent intent, TurnConstraints constraints, CancellationToken ct = default)
    {
        var required = RequiredCapabilities(intent);
        var all = await _catalog.ListAsync(ModelQuery.Any, ct);
        var capable = all.Where(m => (m.Capabilities & required) == required).ToList();

        if (capable.Count == 0)
        {
            throw new InvalidOperationException(
                $"No model in the catalog satisfies required capabilities '{required}' for intent '{intent}'.");
        }

        if (constraints.ModelHint is { Length: > 0 } hint)
        {
            var hinted = capable.FirstOrDefault(m => m.ModelId == hint);

            if (hinted is not null)
            {
                var hintedAlternatives = capable.Where(m => m.ModelId != hinted.ModelId).Select(m => m.ModelId).ToArray();

                return new ModelSelection(
                    hinted,
                    new DecisionTrace(
                        $"Selected hinted model '{hinted.ModelId}'",
                        $"TurnConstraints.ModelHint satisfies required capabilities '{required}'",
                        hintedAlternatives));
            }
        }

        var withinBudget = constraints.MaxCost is { } maxCost
            ? capable.Where(m => m.CostPer1kIn + m.CostPer1kOut <= maxCost).ToList()
            : capable;

        var costCandidates = withinBudget.Count > 0 ? withinBudget : capable;

        var withinLatency = constraints.LatencyBudget is { } latencyBudget
            ? costCandidates.Where(m => LatencyFits(m.Latency, latencyBudget)).ToList()
            : costCandidates;

        var final = withinLatency.Count > 0 ? withinLatency : costCandidates;

        var selected = final
            .OrderBy(m => m.CostPer1kIn + m.CostPer1kOut)
            .ThenBy(m => m.Latency)
            .First();

        var why = new StringBuilder($"Ordered {final.Count} capability-matching model(s) by cost then latency class.");

        if (constraints.MaxCost is not null && withinBudget.Count == 0)
        {
            why.Append(" No model met TurnConstraints.MaxCost; the budget constraint was relaxed.");
        }

        if (constraints.LatencyBudget is not null && withinLatency.Count == 0)
        {
            why.Append(" No model met TurnConstraints.LatencyBudget; the latency constraint was relaxed.");
        }

        var alternatives = final.Where(m => m.ModelId != selected.ModelId).Select(m => m.ModelId).ToArray();

        return new ModelSelection(selected, new DecisionTrace($"Selected model '{selected.ModelId}'", why.ToString(), alternatives));
    }

    private static ModelCapabilities RequiredCapabilities(TurnIntent intent) => intent switch
    {
        TurnIntent.Question => ModelCapabilities.Chat,
        TurnIntent.Task => ModelCapabilities.Chat | ModelCapabilities.ToolUse,
        TurnIntent.Planning => ModelCapabilities.Chat | ModelCapabilities.StructuredOutput,
        TurnIntent.Approval => ModelCapabilities.Chat,
        TurnIntent.Event => ModelCapabilities.Chat,
        TurnIntent.Unclear => ModelCapabilities.Chat,
        _ => throw new ArgumentOutOfRangeException(nameof(intent), intent, null)
    };

    private static bool LatencyFits(LatencyClass latency, TimeSpan budget) => latency switch
    {
        LatencyClass.Low => true,
        LatencyClass.Medium => budget >= TimeSpan.FromSeconds(5),
        LatencyClass.High => budget >= TimeSpan.FromSeconds(15),
        _ => throw new ArgumentOutOfRangeException(nameof(latency), latency, null)
    };
}
