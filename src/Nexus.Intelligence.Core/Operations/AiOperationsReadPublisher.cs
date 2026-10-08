using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>The result of asking the publisher to write a document.</summary>
/// <remarks>
/// <b>A refusal is a result, not an exception.</b> A caller that has to catch to learn a publication
/// did not happen will eventually forget to, and a destination that was read-only for one run would
/// then look exactly like one that published. The reason travels with the outcome so an operator is
/// told which of the two happened.
/// </remarks>
public sealed record AiOperationsPublishOutcome(
    bool Published,
    string? Path,
    string PayloadDigest,
    string Reason)
{
    /// <summary>A publication that did not happen, with the reason it did not.</summary>
    public static AiOperationsPublishOutcome Refused(string reason, string digest = "")
        => new(false, null, digest, reason);
}

/// <summary>
/// Writes the AI Head's operations read model to a file, atomically and idempotently.
/// </summary>
/// <remarks>
/// <para>
/// <b>The shape is the estate's, not this lane's invention.</b> Nexus Platform publishes its Delivery
/// and DevelopmentControl read models through publishers with the same lifecycle — project, validate,
/// serialise once, stage, rename, bounded retry, per-destination gate — and this type exists so the AI
/// Head is the fourth authority on one mechanism rather than the first on a second one. Where this
/// differs it is recorded in the member's own remarks, and every difference is a hardening rather than
/// a divergence in behaviour.
/// </para>
/// <para>
/// <b>Serialised once, before any attempt.</b> Every retry below commits the exact bytes the first
/// attempt produced. A retry that re-projected would publish a document assembled from a second read of
/// authority that may have moved, and the digest it carried would describe a document nobody wrote.
/// </para>
/// <para>
/// <b>Idempotent by construction rather than by skipping.</b> The digest covers the payload and nothing
/// else, so republishing unchanged facts produces an identical digest while the two instants on the
/// envelope move. A caller that wants to know whether anything changed compares
/// <see cref="PublishedDigest"/> across the call; the publisher itself always writes, because a
/// publisher that skipped when it believed nothing had changed would be trusting its own comparison
/// rather than the caller's.
/// </para>
/// </remarks>
public sealed class AiOperationsReadPublisher
{
    /// <summary>
    /// How many times a transient commit failure is retried.
    /// </summary>
    /// <remarks>
    /// Bounded, and the bound is the point: an unbounded retry against a genuinely stuck destination
    /// turns a refusal into a hang, and a hang in a publication step is indistinguishable from a
    /// publisher that is working slowly. The estate's other publishers use this same number so that
    /// "how long does a publication take to fail" has one answer across the estate.
    /// </remarks>
    private const int MaxCommitAttempts = 20;

    /// <summary>The delay before each retry. The last value repeats.</summary>
    private static readonly TimeSpan[] CommitBackoff =
    [
        TimeSpan.FromMilliseconds(10),
        TimeSpan.FromMilliseconds(20),
        TimeSpan.FromMilliseconds(40),
        TimeSpan.FromMilliseconds(80),
        TimeSpan.FromMilliseconds(160),
        TimeSpan.FromMilliseconds(200),
    ];

    /// <summary>The wall-clock ceiling on the whole commit, retries and gate wait included.</summary>
    private static readonly TimeSpan CommitBudget = TimeSpan.FromSeconds(2);

    /// <summary>
    /// One gate per destination, so two publishers writing to different directories never contend.
    /// </summary>
    /// <remarks>
    /// Keyed on the destination path and not process-wide. A single global gate would serialise the
    /// estate's publications against each other, which is a correctness-preserving change that would
    /// make one slow destination everyone's problem.
    /// </remarks>
    private static readonly ConcurrentDictionary<string, object> CommitGates =
        new(StringComparer.OrdinalIgnoreCase);

    private readonly AiOperationsPublicationProjection _projection;

    /// <summary>Composes the publisher over a projection.</summary>
    public AiOperationsReadPublisher(AiOperationsPublicationProjection projection)
    {
        ArgumentNullException.ThrowIfNull(projection);
        _projection = projection;
    }

    /// <summary>
    /// Reads which payload digest is currently published, or null when nothing readable is.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The reader side of the idempotency contract, and the only read-back this type offers. It reads
    /// one member rather than deserialising the document because its caller is deciding whether to
    /// report a change, and a caller that could deserialise here would eventually act on what it read.
    /// </para>
    /// <para>
    /// A file that exists and cannot be parsed answers null — deliberately the same answer as a file
    /// that is not there. Both mean "there is no digest here to compare against", and the caller's next
    /// step is identical: publish and report what happened.
    /// </para>
    /// </remarks>
    public static string? PublishedDigest(string destinationDirectory)
    {
        if (string.IsNullOrWhiteSpace(destinationDirectory))
        {
            return null;
        }

        var path = System.IO.Path.Combine(destinationDirectory, AiOperationsReadContract.DocumentFileName);

        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            // Stripped before parsing because a byte-order mark is legal at the head of a UTF-8 file
            // and System.Text.Json refuses one. A consumer that did not strip it would report a
            // malformed document for a file this estate's own writer produced.
            var text = File.ReadAllText(path).TrimStart('﻿');

            using var document = JsonDocument.Parse(text);

            return document.RootElement.TryGetProperty("Source", out var source)
                && source.TryGetProperty("PayloadDigest", out var digest)
                    ? digest.GetString()
                    : null;
        }
        catch (JsonException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>Projects the estate and writes the document to a destination directory.</summary>
    /// <param name="destinationDirectory">An absolute directory. Never guessed and never relative.</param>
    /// <param name="observedAt">
    /// The instant the facts were observed. Supplied rather than read from a clock here, so that a
    /// projection over a fixed input is reproducible.
    /// </param>
    /// <param name="cancellationToken">Cancels the projection, never a commit.</param>
    public async Task<AiOperationsPublishOutcome> PublishAsync(
        string destinationDirectory,
        DateTimeOffset observedAt,
        CancellationToken cancellationToken = default)
    {
        var destinationRefusal = ValidateDestination(destinationDirectory);

        if (destinationRefusal is not null)
        {
            return AiOperationsPublishOutcome.Refused(destinationRefusal);
        }

        var finalPath = System.IO.Path.Combine(
            destinationDirectory,
            AiOperationsReadContract.DocumentFileName);

        AiOperationsReadModelPayload payload;

        try
        {
            payload = await _projection.ProjectAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Prefix a recognisable marker so a caller can distinguish "the authority could not be read"
            // from "the destination could not be written" without parsing prose.
            return AiOperationsPublishOutcome.Refused(
                $"AUTHORITY_UNAVAILABLE — the AI Head's own composition could not be projected: {ex.Message}");
        }

        var digest = AiOperationsDigest.Of(payload);

        var instant = observedAt.ToString("O", CultureInfo.InvariantCulture);

        var model = new AiOperationsReadModelDocument(
            AiOperationsReadContract.SchemaVersion,
            new AiOperationsReadSource(
                AiOperationsReadContract.SchemaVersion,
                AiOperationsReadContract.Authority,
                AiOperationsReadContract.SourceId,
                _projection.SourceRevision,
                instant,
                instant,
                digest),
            payload);

        var contractRefusal = Validate(model);

        if (contractRefusal is not null)
        {
            return AiOperationsPublishOutcome.Refused(contractRefusal, digest);
        }

        // Serialised ONCE. Every attempt below commits these exact bytes.
        var json = JsonSerializer.Serialize(model, AiOperationsJson.Published);

        var committed = CommitAtomically(finalPath, json, out var commitReason);

        return committed
            ? new AiOperationsPublishOutcome(true, finalPath, digest, commitReason)
            : AiOperationsPublishOutcome.Refused(commitReason, digest);
    }

    // --- Validation -----------------------------------------------------------------------------------

    /// <summary>Refuses a destination that cannot be the place a governed publication goes.</summary>
    private static string? ValidateDestination(string destinationDirectory)
    {
        if (string.IsNullOrWhiteSpace(destinationDirectory))
        {
            return "no destination was named. The published location is a governed decision and is never "
                + "guessed: pass one explicitly.";
        }

        if (!System.IO.Path.IsPathRooted(destinationDirectory))
        {
            return $"'{destinationDirectory}' is not an absolute path. A relative destination resolves "
                + "against the process's working directory, so two runs could publish to two places and "
                + "neither would say so.";
        }

        try
        {
            Directory.CreateDirectory(destinationDirectory);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return $"the destination '{destinationDirectory}' could not be created: {ex.Message}";
        }

        return null;
    }

    /// <summary>
    /// Refuses a document a consumer would refuse, before any byte is written.
    /// </summary>
    /// <remarks>
    /// The checks here are the ones a consumer makes. Running them in the producer means a defective
    /// document is a failed publication the operator is told about, rather than a file that appears to
    /// have published and is refused by every reader.
    /// </remarks>
    private string? Validate(AiOperationsReadModelDocument model)
    {
        if (!string.Equals(
                model.SchemaVersion,
                AiOperationsReadContract.SchemaVersion,
                StringComparison.Ordinal))
        {
            return $"the projection declared contract version '{model.SchemaVersion}', which is not "
                + $"'{AiOperationsReadContract.SchemaVersion}'.";
        }

        if (string.IsNullOrWhiteSpace(model.Source.SourceId))
        {
            return "the projection does not identify its source.";
        }

        if (model.Source.PayloadDigest.Length != AiOperationsDigest.PrefixedLength
            || !model.Source.PayloadDigest.StartsWith(AiOperationsDigest.Prefix, StringComparison.Ordinal))
        {
            return $"the payload digest '{model.Source.PayloadDigest}' is not a "
                + $"{AiOperationsDigest.Prefix} prefixed lower-case hex digest.";
        }

        // Recomputed from the payload rather than trusted. A digest that the producer computed over
        // something other than what it shipped would be a value no consumer could ever reproduce, and
        // the failure would surface as every reader refusing the document.
        if (!AiOperationsDigest.VerifiesPayload(model.Payload, model.Source.PayloadDigest))
        {
            return "the payload digest does not describe the payload. The document was assembled from "
                + "parts that disagree, which is a defect in the projection rather than in the "
                + "destination.";
        }

        if (!DateTimeOffset.TryParse(
                model.Source.ObservedAt,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out _))
        {
            return $"the observation instant '{model.Source.ObservedAt}' is not a parseable timestamp.";
        }

        return null;
    }

    // --- Atomic commit --------------------------------------------------------------------------------

    /// <summary>
    /// Stages the document beside its destination and renames it into place.
    /// </summary>
    /// <remarks>
    /// The rename is the commit point. A reader therefore sees either the previous document or the new
    /// one and never a half-written file, which a direct write to the destination cannot promise.
    /// </remarks>
    private static bool CommitAtomically(string finalPath, string json, out string reason)
    {
        // Started before the gate: time spent waiting on another publisher counts against the budget,
        // so a contended destination is reported as slow rather than as repeatedly failing.
        var clock = Stopwatch.StartNew();

        var gate = CommitGates.GetOrAdd(finalPath, _ => new object());

        lock (gate)
        {
            // Unique per attempt run and in the destination directory itself, so the rename is a
            // rename and not a copy across volumes.
            var stagingPath = finalPath + "." + Guid.NewGuid().ToString("N")[..12] + ".staging";

            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    File.WriteAllText(stagingPath, json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

                    // The commit point.
                    File.Move(stagingPath, finalPath, overwrite: true);

                    reason = "published";
                    return true;
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or DirectoryNotFoundException)
                {
                    TryRemoveStaging(stagingPath);

                    if (IsReadOnlyDestination(finalPath))
                    {
                        reason = $"the destination '{finalPath}' is read-only. This is a configuration "
                            + "condition, not transient contention, so it is not retried.";
                        return false;
                    }

                    if (Directory.Exists(finalPath))
                    {
                        // Windows raises the same access-denied for a directory destination as for a
                        // transient handle, so the exception's type is a hint and the filesystem's own
                        // state is the evidence.
                        reason = $"'{finalPath}' is a directory. A file cannot be moved over a directory "
                            + "on any filesystem, so this is a permanent condition and is not retried.";
                        return false;
                    }

                    var transient = IsTransientCommitContention(ex);
                    var attemptsLeft = attempt < MaxCommitAttempts;
                    var budgetLeft = clock.Elapsed < CommitBudget;

                    if (!transient || !attemptsLeft || !budgetLeft)
                    {
                        reason = transient
                            ? $"the destination '{finalPath}' stayed busy. Retried {attempt} time(s) over "
                                + $"{clock.ElapsedMilliseconds} ms and gave up (budget: {MaxCommitAttempts} "
                                + "attempts / 2 s). The previously published document, if any, is unchanged."
                            : $"the destination '{finalPath}' could not be written: {ex.Message.TrimEnd('.')}. "
                                + "This is not a transient-contention condition, so it is not retried. The "
                                + "previously published document, if any, is unchanged.";

                        return false;
                    }

                    Thread.Sleep(CommitBackoff[Math.Min(attempt - 1, CommitBackoff.Length - 1)]);
                }
            }
        }
    }

    /// <summary>
    /// Whether a failed commit is worth retrying, reasoned from the failure rather than matched from
    /// its text.
    /// </summary>
    /// <remarks>
    /// <b>Deliberately narrow.</b> Retrying everything would turn a full disk into a two-second stall
    /// before the same refusal; retrying nothing would fail every publication that collided with an
    /// antivirus scanner holding the destination open for ten milliseconds. The two conditions below
    /// are the ones a second attempt can actually fix, and anything else propagates as an immediate
    /// refusal.
    /// </remarks>
    private static bool IsTransientCommitContention(Exception ex)
    {
        switch (ex)
        {
            case UnauthorizedAccessException:
                // Windows raises this for a shared or denied handle on a file that exists, which is
                // transient, and for a genuinely protected path, which the read-only probe above has
                // already separated out.
                return true;

            case IOException io:
                const int ErrorSharingViolation = 32;
                const int ErrorLockViolation = 33;

                var code = io.HResult & 0xFFFF;

                return code is ErrorSharingViolation or ErrorLockViolation;

            default:
                return false;
        }
    }

    private static bool IsReadOnlyDestination(string finalPath)
    {
        try
        {
            return File.Exists(finalPath)
                && File.GetAttributes(finalPath).HasFlag(FileAttributes.ReadOnly);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Falling through to the ordinary classifier is the honest answer: this probe could not
            // establish that the destination is read-only, and reporting it as such would refuse a
            // publication on the strength of a check that did not complete.
            return false;
        }
    }

    private static void TryRemoveStaging(string stagingPath)
    {
        try
        {
            if (File.Exists(stagingPath))
            {
                File.Delete(stagingPath);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Best effort. A staging file that survives is untidy and is not a published document —
            // consumers read one fixed filename, and it is not this one.
        }
    }
}
