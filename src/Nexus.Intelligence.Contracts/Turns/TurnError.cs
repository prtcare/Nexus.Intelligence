namespace Nexus.Intelligence.Contracts;

public sealed record TurnError(string Code, string Message, string? Detail);
