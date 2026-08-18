using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Agents.Abstractions;

public sealed record AgentContext(ScopeRef Scope, ActorRef Actor, AgentType Type);
