namespace Nexus.Intelligence.Contracts;

public interface IIntelligenceClient
{
    Task<IntelligenceTurnResponse> SendTurnAsync(IntelligenceTurnRequest request, CancellationToken ct = default);

    Task ReportResultAsync(ResultReport report, CancellationToken ct = default);
}
