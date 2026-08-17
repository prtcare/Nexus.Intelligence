namespace NexusAI.Core.Agents;

public sealed record AgentContext(
    string ProjectId,
    string ConversationId,
    string WorkspaceId,
    AgentType AgentType);