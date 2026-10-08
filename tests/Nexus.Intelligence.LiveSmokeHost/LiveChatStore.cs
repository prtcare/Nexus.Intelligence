using System.Text.Json;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.LiveSmokeHost;

/// <summary>
/// A durable record of one live turn, written where a second process can read it.
/// </summary>
/// <remarks>
/// <para>
/// <b>Test-harness persistence, not estate persistence, and the distinction is deliberate.</b> The
/// estate meters usage in memory (<c>InMemoryAiOperationsLedger</c>) and holds no model output at
/// all — an assistant message belongs to the product that asked for it, and the AI Head is not the
/// product's store. So there is nothing in the estate for a restart assertion to read. What the
/// assertion is really about is that the message <i>reached a caller intact</i>, and a file written
/// by one process and read by another is the smallest honest way to show that: it proves the bytes
/// survived the process that produced them, which is the property the retired Platform smoke check
/// existed to demonstrate.
/// </para>
/// <para>
/// This is provider-neutral code — it names no vendor and holds no credential — which is exactly
/// why it can live here without contradicting the ownership boundary. What makes the suite
/// provider-specific is the estate it composes, not this file.
/// </para>
/// </remarks>
public static class LiveChatStore
{
    /// <summary>
    /// The directory a restarted process reads from. Derived from the host's own output directory,
    /// so the two processes agree without either being told where the other ran.
    /// </summary>
    public static string DataDirectory { get; } = Path.Combine(AppContext.BaseDirectory, ".live-smoke-data");

    public static string Save(LiveTurnRecord record)
    {
        Directory.CreateDirectory(DataDirectory);

        var path = Path.Combine(DataDirectory, record.RecordId + ".json");
        File.WriteAllText(path, JsonSerializer.Serialize(record, JsonOptions));

        return path;
    }

    public static LiveTurnRecord? Load(string recordId)
    {
        var path = Path.Combine(DataDirectory, recordId + ".json");

        return File.Exists(path)
            ? JsonSerializer.Deserialize<LiveTurnRecord>(File.ReadAllText(path), JsonOptions)
            : null;
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };
}

/// <summary>
/// One live turn as it is persisted. Every member is something a caller was actually given, so the
/// record cannot claim more than the response did.
/// </summary>
public sealed record LiveTurnRecord(
    string RecordId,
    string Prompt,
    string? AssistantOutput,
    string ExecutionId,
    int? InputTokens,
    int? OutputTokens,
    DateTimeOffset RecordedAt)
{
    /// <summary>
    /// Projects a real capability response. Throws for a non-success response rather than recording
    /// one, because a record of a refused turn would satisfy every assertion below while proving
    /// nothing about the provider.
    /// </summary>
    public static LiveTurnRecord From(AiCapabilityResponse response, string prompt)
    {
        if (response.Status != AiExecutionStatus.Succeeded)
        {
            throw new InvalidOperationException(
                $"the live turn did not succeed: status={response.Status}, "
                + $"failure={response.Failure?.Code} ({response.Failure?.Message})");
        }

        return new LiveTurnRecord(
            Guid.NewGuid().ToString("N"),
            prompt,
            response.Output,
            response.Execution?.ExecutionId ?? string.Empty,
            response.Usage.InputTokens,
            response.Usage.OutputTokens,
            DateTimeOffset.UtcNow);
    }
}
