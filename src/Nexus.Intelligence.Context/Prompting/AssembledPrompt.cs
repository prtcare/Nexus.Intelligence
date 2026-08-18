using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Context.Prompting;

public sealed record AssembledPrompt(
    IReadOnlyList<ModelMessage> Messages,
    IReadOnlyList<string> IncludedContextItemIds,
    int EstimatedTokens);
