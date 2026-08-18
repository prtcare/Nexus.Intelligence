namespace Nexus.Intelligence.Contracts;

public sealed record PlanPayload(IReadOnlyList<PlanStep> Steps);
