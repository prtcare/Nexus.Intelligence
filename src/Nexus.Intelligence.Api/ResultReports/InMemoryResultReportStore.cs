using System.Collections.Concurrent;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Api.ResultReports;

public sealed class InMemoryResultReportStore : IResultReportStore
{
    private readonly ConcurrentBag<ResultReport> _reports = [];

    public Task AddAsync(ResultReport report, CancellationToken ct = default)
    {
        _reports.Add(report);
        return Task.CompletedTask;
    }
}
