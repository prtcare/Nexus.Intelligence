using NexusAI.Domain.Common.Identifiers;
using NexusAI.Domain.Project;
using NexusAI.Domain.Workspace;

namespace NexusAI.Domain.Memory;

public interface IMemoryRepository
{
    Task AddAsync(
        Memory memory,
        CancellationToken cancellationToken = default);

    Task<Memory?> GetAsync(
        MemoryId memoryId,
        CancellationToken cancellationToken = default);

    Task UpdateAsync(
        Memory memory,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<Memory>> ListByWorkspaceAsync(
        WorkspaceId workspaceId,
        CancellationToken cancellationToken = default);
}