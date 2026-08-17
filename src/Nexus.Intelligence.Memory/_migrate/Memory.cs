using NexusAI.Domain.Common.Identifiers;
using NexusAI.Domain.Conversation;
using NexusAI.Domain.Project;
using NexusAI.Domain.Workspace;

namespace NexusAI.Domain.Memory;

public sealed class Memory
{
    public MemoryId Id { get; private set; }

    public WorkspaceId WorkspaceId { get; private set; }

    public ProjectId? ProjectId { get; private set; }

    public ConversationId? ConversationId { get; private set; }

    public MemoryType Type { get; private set; }

    public MemorySource Source { get; private set; }

    public string Content { get; private set; }

    public string Keywords { get; private set; }

    public string Metadata { get; private set; }

    public DateTimeOffset CreatedAt { get; private set; }

    private Memory()
    {
        Content = string.Empty;
        Keywords = string.Empty;
        Metadata = string.Empty;
    }

    public Memory(
        MemoryId id,
        WorkspaceId workspaceId,
        ProjectId? projectId,
        ConversationId? conversationId,
        MemoryType type,
        MemorySource source,
        string content,
        string keywords,
        string metadata,
        DateTimeOffset createdAt)
    {
        if (id.Value == Guid.Empty)
        {
            throw new ArgumentException(
                "Memory id cannot be empty.",
                nameof(id));
        }

        if (workspaceId.Value == Guid.Empty)
        {
            throw new ArgumentException(
                "Workspace id cannot be empty.",
                nameof(workspaceId));
        }

        if (projectId.HasValue &&
            projectId.Value.Value == Guid.Empty)
        {
            throw new ArgumentException(
                "Project id cannot be empty.",
                nameof(projectId));
        }

        if (conversationId.HasValue &&
            conversationId.Value.Value == Guid.Empty)
        {
            throw new ArgumentException(
                "Conversation id cannot be empty.",
                nameof(conversationId));
        }

        if (string.IsNullOrWhiteSpace(content))
        {
            throw new ArgumentException(
                "Memory content cannot be empty.",
                nameof(content));
        }

        Id = id;
        WorkspaceId = workspaceId;
        ProjectId = projectId;
        ConversationId = conversationId;
        Type = type;
        Source = source;
        Content = content.Trim();
        Keywords = keywords?.Trim() ?? string.Empty;
        Metadata = metadata?.Trim() ?? string.Empty;
        CreatedAt = createdAt;
    }
}