using Nexus.Intelligence.Agents.Abstractions;
using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Core.Turns;

public interface IPromptStep
{
    PromptStepResult Assemble(
        TurnInput input,
        IReadOnlyList<RankedContextItem> rankedContext,
        ModelDescriptor model,
        IAgent agent,
        IReadOnlyList<ToolDescriptor> availableTools);
}
