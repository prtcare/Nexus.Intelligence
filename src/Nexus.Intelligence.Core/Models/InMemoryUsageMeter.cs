using System.Collections.Concurrent;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Platform.Core.Models;

public sealed class InMemoryUsageMeter : IUsageMeter
{
    private readonly ConcurrentQueue<UsageRecord> _records = [];

    public IReadOnlyCollection<UsageRecord> Records => _records;

    public Task RecordAsync(UsageRecord record, CancellationToken ct = default)
    {
        _records.Enqueue(record);
        return Task.CompletedTask;
    }
}
