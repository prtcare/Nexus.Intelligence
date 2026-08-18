using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Execution;

public sealed record ExecutionContext(ScopeRef Scope, ActorRef Actor);
