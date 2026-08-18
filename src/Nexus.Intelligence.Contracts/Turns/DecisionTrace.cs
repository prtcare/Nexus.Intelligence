namespace Nexus.Intelligence.Contracts;

/// <summary>Why this model, this agent, these context items. The explanation endpoint reads these.</summary>
public sealed record DecisionTrace(string What, string Why, IReadOnlyList<string> Alternatives);
