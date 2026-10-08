using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Api.Operations;

/// <summary>
/// Runs the configured health probes on an interval, outside every routing decision.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the "live" half of the live health snapshot, and it lives in the host rather than in the
/// core.</b> A background service is a hosting concern: it owns a lifetime, a cancellation token and a
/// scheduling cadence, none of which belong to a library that must be usable from a test with no host
/// at all. The core ships the runner — which does the work and can be awaited once, deterministically,
/// from a test — and this type only decides when to call it.
/// </para>
/// <para>
/// <b>It is not reachable from routing, and routing is not reachable from it.</b> The sweep holds an
/// <see cref="IAiHealthProbeRunner"/> and nothing else; the router holds an
/// <see cref="IAiModelHealthSource"/> that reads the store this writes. The two never meet, which is
/// what makes "no inline probing" structural rather than a rule someone has to keep.
/// </para>
/// <para>
/// <b>A sweep that fails does not stop the sweep.</b> A probe that throws is already converted to "no
/// answer" inside the runner, but a failure in the runner itself — a malformed target list, a store
/// that refuses a publish — is caught here so that one bad round does not end the loop and leave the
/// estate routing forever on the snapshot it happened to be holding.
/// </para>
/// </remarks>
public sealed class AiHealthProbeService : BackgroundService
{
    private readonly IAiHealthProbeRunner _runner;
    private readonly TimeSpan _interval;
    private readonly ILogger<AiHealthProbeService> _logger;

    /// <summary>Composes the sweep from its runner, its cadence and a logger.</summary>
    public AiHealthProbeService(
        IAiHealthProbeRunner runner,
        TimeSpan interval,
        ILogger<AiHealthProbeService> logger)
    {
        ArgumentNullException.ThrowIfNull(runner);
        ArgumentNullException.ThrowIfNull(logger);

        if (interval <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(interval),
                interval,
                "The probe interval must be positive. A non-positive interval is not a faster sweep, it "
                + "is a loop that never yields.");
        }

        _runner = runner;
        _interval = interval;
        _logger = logger;
    }

    /// <inheritdoc />
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(_interval);

        // The first sweep runs immediately rather than after one interval. Waiting would leave the
        // estate routing on the composition-time seed for a full period after every restart, which is
        // exactly the window in which a probe result is most wanted.
        do
        {
            await SweepAsync(stoppingToken).ConfigureAwait(false);
        }
        while (await SafeWaitAsync(timer, stoppingToken).ConfigureAwait(false));
    }

    /// <summary>Runs one sweep, converting any failure into a log line.</summary>
    private async Task SweepAsync(CancellationToken stoppingToken)
    {
        try
        {
            var snapshot = await _runner.RunOnceAsync(stoppingToken).ConfigureAwait(false);

            _logger.LogDebug(
                "AI health sweep published a snapshot from '{Source}' covering {Providers} provider(s) "
                + "and {Models} model(s).",
                snapshot.Source,
                snapshot.Providers.Count,
                snapshot.Models.Count);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            // Logged without the exception's message reaching any record the estate keeps: a probe
            // reaches a provider, and a captured exception is the most likely carrier of an upstream
            // body. The type name is enough to route the investigation.
            _logger.LogWarning(
                "AI health sweep failed with {ExceptionType}. The published snapshot stands unchanged.",
                ex.GetType().Name);
        }
    }

    /// <summary>Waits for the next tick, reporting cancellation as "stop" rather than as a failure.</summary>
    private static async Task<bool> SafeWaitAsync(PeriodicTimer timer, CancellationToken stoppingToken)
    {
        try
        {
            return await timer.WaitForNextTickAsync(stoppingToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }
}
