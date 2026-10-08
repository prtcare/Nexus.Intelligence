using System.Collections.Concurrent;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// What the estate has observed about its routes, kept as the attempts themselves.
/// </summary>
/// <remarks>
/// <para>
/// <b>The attempts are the record and the summary is derived on read.</b> Storing only running
/// counters would make every question the estate cannot yet ask unanswerable — "what was the most
/// recent failure", "how long is the current failure run" — and answering the second from a counter
/// is impossible without a second counter that has to be kept in step with the first. Deriving costs
/// a walk over a bounded list and cannot drift.
/// </para>
/// <para>
/// <b>Bounded, and honest about what that means.</b> Each route keeps its most recent attempts and
/// discards older ones, so the success rate is a <em>recent</em> rate rather than a lifetime one. That
/// is the right question for a routing gate — a provider that failed all morning and has worked all
/// afternoon should not be refused on the strength of the morning — and it is documented here rather
/// than left for someone to discover from a figure that stops moving.
/// </para>
/// <para>
/// <b>No attempt is ever recorded from inside the attempt it describes.</b> Recording happens after
/// the provider call returns, so the evidence a routing decision reads cannot contain the decision's
/// own outcome. That is what makes a replay reproduce the original routing.
/// </para>
/// </remarks>
public sealed class InMemoryAiReliabilityHistory : IAiReliabilityHistory
{
    /// <summary>How many recent attempts are retained per route.</summary>
    public const int DefaultCapacity = 500;

    private readonly ConcurrentDictionary<(string ProviderId, string ModelId), AttemptLog> _logs = new();
    private readonly int _capacity;
    private readonly TimeProvider _time;

    /// <summary>Builds a history retaining a bounded number of attempts per route.</summary>
    public InMemoryAiReliabilityHistory(TimeProvider time, int capacity = DefaultCapacity)
    {
        ArgumentNullException.ThrowIfNull(time);
        ArgumentOutOfRangeException.ThrowIfLessThan(capacity, 1);

        _time = time;
        _capacity = capacity;
    }

    /// <inheritdoc />
    public void Record(AiReliabilityAttempt attempt)
    {
        ArgumentNullException.ThrowIfNull(attempt);

        var log = _logs.GetOrAdd((attempt.ProviderId, attempt.ModelId), _ => new AttemptLog(_capacity));
        log.Add(attempt);
    }

    /// <inheritdoc />
    public AiReliabilityEvidence EvidenceFor(string providerId, string modelId)
    {
        if (string.IsNullOrWhiteSpace(providerId) || string.IsNullOrWhiteSpace(modelId))
        {
            return AiReliabilityEvidence.None(providerId ?? string.Empty, modelId ?? string.Empty);
        }

        if (!_logs.TryGetValue((providerId, modelId), out var log))
        {
            return AiReliabilityEvidence.None(providerId, modelId);
        }

        var attempts = log.Snapshot();

        if (attempts.Length == 0)
        {
            return AiReliabilityEvidence.None(providerId, modelId);
        }

        var successes = attempts.Count(attempt => attempt.Succeeded);
        var failures = attempts.Where(attempt => !attempt.Succeeded).ToArray();
        var lastFailure = failures.Length == 0 ? null : failures[^1];
        var latencies = attempts
            .Where(attempt => attempt.Latency is not null)
            .Select(attempt => attempt.Latency!.Value)
            .ToArray();

        return new AiReliabilityEvidence
        {
            ProviderId = providerId,
            ModelId = modelId,
            Attempts = attempts.Length,
            Successes = successes,
            FallbackAttempts = attempts.Count(attempt => attempt.IsFallback),
            LastFailureCategory = lastFailure?.FailureCategory,
            ConsecutiveFailures = ConsecutiveFailures(attempts),
            LastFailureAt = lastFailure?.At,
            LastAttemptAt = attempts[^1].At,
            AverageLatency = latencies.Length == 0
                ? null
                : TimeSpan.FromTicks((long)latencies.Average(latency => latency.Ticks)),
        };
    }

    /// <inheritdoc />
    public IReadOnlyList<AiReliabilityAttempt> AttemptsFor(string providerId, string modelId)
    {
        if (string.IsNullOrWhiteSpace(providerId) || string.IsNullOrWhiteSpace(modelId))
        {
            return [];
        }

        return _logs.TryGetValue((providerId, modelId), out var log) ? log.Snapshot() : [];
    }

    /// <inheritdoc />
    public IReadOnlyList<AiReliabilityEvidence> All() => [.. _logs.Keys
        .OrderBy(key => key.ProviderId, StringComparer.Ordinal)
        .ThenBy(key => key.ModelId, StringComparer.Ordinal)
        .Select(key => EvidenceFor(key.ProviderId, key.ModelId))];

    /// <summary>How long evidence has existed, for a reader that needs to know it is fresh.</summary>
    public DateTimeOffset Now() => _time.GetUtcNow();

    /// <summary>
    /// The length of the failure run at the end of the observed sequence.
    /// </summary>
    /// <remarks>
    /// Counted from the most recent attempt backwards and stopped at the first success. A count of
    /// failures anywhere in the window would answer a different question — "has this route been
    /// failing lately" rather than "is it failing now" — and the second is the one a gate acts on.
    /// </remarks>
    private static int ConsecutiveFailures(AiReliabilityAttempt[] attempts)
    {
        var run = 0;

        for (var index = attempts.Length - 1; index >= 0; index--)
        {
            if (attempts[index].Succeeded)
            {
                break;
            }

            run++;
        }

        return run;
    }

    /// <summary>One route's attempt log, bounded and copied on read.</summary>
    /// <remarks>
    /// Copying on read rather than exposing the list means a routing decision sees one coherent
    /// sequence. An enumerator over a list being appended to by a completing execution would throw,
    /// and a routing gate that throws because a request finished is a gate nobody would keep.
    /// </remarks>
    private sealed class AttemptLog
    {
        private readonly Lock _gate = new();
        private readonly List<AiReliabilityAttempt> _attempts;
        private readonly int _capacity;

        public AttemptLog(int capacity)
        {
            _capacity = capacity;
            _attempts = new List<AiReliabilityAttempt>(Math.Min(capacity, 64));
        }

        public void Add(AiReliabilityAttempt attempt)
        {
            lock (_gate)
            {
                _attempts.Add(attempt);

                if (_attempts.Count > _capacity)
                {
                    _attempts.RemoveRange(0, _attempts.Count - _capacity);
                }
            }
        }

        public AiReliabilityAttempt[] Snapshot()
        {
            lock (_gate)
            {
                return [.. _attempts];
            }
        }
    }
}
