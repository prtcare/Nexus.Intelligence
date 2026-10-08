using Nexus.Intelligence.Agents.Abstractions;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

/// <summary>
/// The agent chosen for a turn, identified by the registry's own key.
/// </summary>
/// <remarks>
/// <para>
/// <b><see cref="AgentId"/> is a string from <see cref="IAiAgentRegistry"/>, not an <c>AgentType</c>
/// enum member.</b> Before W7D this record carried an <c>IAgent</c> and an <c>AgentType</c>, and the
/// choice was made by a <c>switch</c> compiled into the assembly — so the set of agents an estate could
/// run was the set of enum members someone had written into C#, and an agent could not be given an
/// instruction set, a tool grant, a classification ceiling or an off switch because no such field
/// existed. The registry's key is now the identity, and the enum has become a detail of one dispatcher.
/// </para>
/// <para>
/// <see cref="Type"/> survives because <see cref="Nexus.Intelligence.Core.Execution.AgentRuntime"/>
/// routes on it, and that path is outside this lane. It is a dispatch detail rather than a selection
/// key: nothing in the governed turn path reads it, and a turn's agent is the one the registry named.
/// </para>
/// </remarks>
public sealed record AgentSelection(string AgentId, AgentType Type, DecisionTrace Decision);
