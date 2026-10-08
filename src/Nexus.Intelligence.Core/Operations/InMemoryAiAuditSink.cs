using System.Collections.Concurrent;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// The in-process audit trail: append-only, keyed by execution, read back under a separate port.
/// </summary>
/// <remarks>
/// <para>
/// <b>It implements the writer and the reader and registers as two ports.</b> The two interfaces stay
/// separate because writing audit evidence and reading it are different acts with different
/// authorization stories — every execution writes one, and only an operator under authority reads them
/// — and a later lane can replace one without touching the other. That the in-process implementation
/// happens to serve both is a property of this implementation, not of the ports.
/// </para>
/// <para>
/// <b>A second write for the same execution replaces the first.</b> An execution has one audit record,
/// and the last thing written about it is the thing that happened. Appending instead would make
/// <see cref="Find"/> depend on which of two records a reader reached first.
/// </para>
/// <para>
/// <b>Bounded reads, unbounded storage.</b> <see cref="Recent"/> is bounded because an operations
/// surface asking for "the latest records" must not receive the whole trail; the trail itself is not
/// capped here, because dropping audit evidence to save memory is the trade an audit store exists to
/// refuse. A deployment that needs a bound replaces this implementation with a durable one.
/// </para>
/// </remarks>
public sealed class InMemoryAiAuditSink : IAiAuditSink, IAiAuditReader
{
    private readonly ConcurrentDictionary<string, Entry> _records = new(StringComparer.Ordinal);
    private long _sequence;

    /// <inheritdoc />
    public int Count => _records.Count;

    /// <inheritdoc />
    public void Write(AiAuditRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);

        var sequence = Interlocked.Increment(ref _sequence);
        _records[record.ExecutionId] = new Entry(sequence, record);
    }

    /// <inheritdoc />
    public AiAuditRecord? Find(string executionId)
    {
        if (string.IsNullOrWhiteSpace(executionId))
        {
            return null;
        }

        return _records.TryGetValue(executionId, out var entry) ? entry.Record : null;
    }

    /// <inheritdoc />
    public IReadOnlyList<AiAuditRecord> FindMany(IEnumerable<string> executionIds)
    {
        ArgumentNullException.ThrowIfNull(executionIds);

        var found = new List<AiAuditRecord>();

        foreach (var executionId in executionIds)
        {
            if (Find(executionId) is { } record)
            {
                found.Add(record);
            }
        }

        return found;
    }

    /// <inheritdoc />
    public IReadOnlyList<AiAuditRecord> Recent(int max)
    {
        if (max <= 0)
        {
            return [];
        }

        return [.. _records.Values
            .OrderByDescending(entry => entry.Sequence)
            .Take(max)
            .Select(entry => entry.Record)];
    }

    /// <summary>
    /// The write sequence number, which is what makes "most recent" well defined.
    /// </summary>
    /// <remarks>
    /// The record's own <see cref="AiAuditRecord.Timestamp"/> is caller-supplied and two executions can
    /// carry the same instant, so ordering by it would make <see cref="Recent"/> depend on dictionary
    /// enumeration order for ties. The sequence is assigned by the store and cannot tie.
    /// </remarks>
    private readonly record struct Entry(long Sequence, AiAuditRecord Record);
}

/// <summary>
/// The in-process store for per-execution routing and operational evidence.
/// </summary>
/// <remarks>
/// <b>The same shape as the audit trail and deliberately not the same store.</b> The two hold
/// different kinds of fact — audit evidence is what governance decided, execution evidence is what the
/// routing and operational gates observed — and merging them would produce one record that a reader
/// could not tell had two independent writers.
/// </remarks>
public sealed class InMemoryAiExecutionEvidenceStore : IAiExecutionEvidenceStore
{
    private readonly ConcurrentDictionary<string, Entry> _evidence = new(StringComparer.Ordinal);
    private long _sequence;

    /// <inheritdoc />
    public int Count => _evidence.Count;

    /// <inheritdoc />
    public void Write(AiExecutionEvidence evidence)
    {
        ArgumentNullException.ThrowIfNull(evidence);

        var sequence = Interlocked.Increment(ref _sequence);
        _evidence[evidence.ExecutionId] = new Entry(sequence, evidence);
    }

    /// <inheritdoc />
    public AiExecutionEvidence? Find(string executionId)
    {
        if (string.IsNullOrWhiteSpace(executionId))
        {
            return null;
        }

        return _evidence.TryGetValue(executionId, out var entry) ? entry.Evidence : null;
    }

    /// <inheritdoc />
    public IReadOnlyList<string> RecentExecutionIds(int max)
    {
        if (max <= 0)
        {
            return [];
        }

        return [.. _evidence.Values
            .OrderByDescending(entry => entry.Sequence)
            .Take(max)
            .Select(entry => entry.Evidence.ExecutionId)];
    }

    private readonly record struct Entry(long Sequence, AiExecutionEvidence Evidence);
}
