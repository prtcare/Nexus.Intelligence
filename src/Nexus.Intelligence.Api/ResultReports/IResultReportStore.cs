using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Api.ResultReports;

public interface IResultReportStore
{
    Task AddAsync(ResultReport report, CancellationToken ct = default);
}
