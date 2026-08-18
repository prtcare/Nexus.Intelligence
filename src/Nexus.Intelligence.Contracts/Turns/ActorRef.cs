namespace Nexus.Intelligence.Contracts;

public sealed record ActorRef(string UserId, IReadOnlyList<string> Roles, IReadOnlyList<string> Permissions);
