using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public sealed record PromptStepResult(AssembledPrompt Prompt, DecisionTrace Decision);
