using System.Runtime.CompilerServices;
using Microsoft.Extensions.Options;
using Nexus.Platform.Contracts.Core;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Contracts.Secrets;
using Nexus.Platform.Core.Models;
using OpenAI.Chat;

namespace Nexus.Platform.Providers.OpenAI;

public sealed class OpenAIModelGateway : INamedModelGateway
{
    private readonly OpenAIOptions _options;
    private readonly IQuotaPolicy _quotaPolicy;
    private readonly IUsageMeter _usageMeter;
    private readonly IAuditLog _auditLog;
    private readonly ISecretResolver _secrets;

    public string Vendor => "openai";

    public OpenAIModelGateway(
        IOptions<OpenAIOptions> options,
        IQuotaPolicy quotaPolicy,
        IUsageMeter usageMeter,
        IAuditLog auditLog,
        ISecretResolver secrets)
    {
        _options = options.Value;
        _quotaPolicy = quotaPolicy;
        _usageMeter = usageMeter;
        _auditLog = auditLog;
        _secrets = secrets;
    }

    /// <summary>
    /// W5E / D-14: obtains the credential through the NEUTRAL secret-access boundary
    /// instead of reading it out of a bound options property.
    ///
    /// Resolved at the point of use and NOT cached in a field, for two reasons: a rotated
    /// secret is then picked up without a host restart, and this assembly never retains
    /// the value beyond the call that needs it. Returns <c>string.Empty</c> when the
    /// reference is unset, which preserves the previous behaviour exactly -- the SDK was
    /// always handed an empty key in that case and surfaced its own error, which the
    /// existing catch turns into <c>Success = false</c>. No behaviour drift.
    ///
    /// The REFERENCE NAME is configuration, not code: this assembly never learns which
    /// environment variable or store path backs it.
    /// </summary>
    private async Task<string> ResolveApiKeyAsync(CancellationToken ct)
        => await _secrets.ResolveAsync(_options.ApiKeyRef, ct) ?? string.Empty;

    public async Task<ModelGatewayOutcome> InvokeReportingUsageAsync(ModelInvocation invocation, CancellationToken ct = default)
    {
        var verdict = await _quotaPolicy.CheckAsync(invocation.Identity, invocation.ModelId, ct);
        if (!verdict.Allowed)
        {
            await _auditLog.AppendAsync(AuditEntryFor(invocation, success: false, verdict.Reason), ct);

            // Failure is deliberately left unset, and this is the one return in this method where that
            // is a decision rather than an omission.
            //
            // A quota denial is not a provider failure: it is this estate declining to make the call, on
            // a policy the estate owns, decided before any vendor was contacted. Classifying it here
            // would put a provider-neutral label on a fact that has nothing to do with a provider, and
            // it would change behaviour above the seam - the AI Head would stop treating it as a
            // retryable unavailability, and a denial the estate issued itself would stop being eligible
            // for failover. The layer that made this decision is the layer that owns its category.
            //
            // Unmeasured, and correctly so: no vendor was contacted, so no usage exists to report.
            return ModelGatewayOutcome.Unmeasured(new ModelInvocationResult
            {
                Success = false,
                Error = verdict.Reason ?? "Quota exceeded",
                ModelUsed = invocation.ModelId
            });
        }

        try
        {
            var apiKey = await ResolveApiKeyAsync(ct);
            var chatClient = new ChatClient(model: ModelName(invocation.ModelId), apiKey: apiKey);
            var messages = invocation.Messages.Select(ToOpenAIMessage).ToList();

            var completion = await chatClient.CompleteChatAsync(messages, cancellationToken: ct);

            // THE PROVIDER'S OWN USAGE BLOCK, OR NOTHING. `Usage` is nullable in the SDK, and this is the
            // only layer in the estate that can observe whether it was there.
            //
            // This used to read `Usage?.InputTokenCount ?? 0`, which turned "the vendor told us nothing"
            // into "the vendor told us zero" — and because the cost basis is derived from these counts,
            // that fabricated zero became a real decimal from CostOf(0, 0) and was then labelled
            // ActualRecorded: a MEASURED cost of nothing, which every budget ceiling passes. Absence is
            // now carried as absence, out of band, because Platform's ModelUsage is non-nullable and
            // cannot express it (see ModelGatewayOutcome).
            var reportedUsage = completion.Value.Usage;

            var usage = new ModelUsage(
                reportedUsage?.InputTokenCount ?? 0,
                reportedUsage?.OutputTokenCount ?? 0,
                0m);

            await _usageMeter.RecordAsync(UsageRecordFor(invocation, usage), ct);
            await _auditLog.AppendAsync(AuditEntryFor(invocation, success: true, "Invoked"), ct);

            return new ModelGatewayOutcome
            {
                // The Platform shape still carries the zero-filled counts, because the type has no other
                // value to carry. It is not the authority for the cost basis — TokensIn/TokensOut below
                // are, and they are null when the provider said nothing.
                Result = new ModelInvocationResult
                {
                    Success = true,
                    Message = new ModelMessage
                    {
                        Role = ModelRole.Assistant,
                        Content = completion.Value.Content.Count > 0 ? completion.Value.Content[0].Text : string.Empty
                    },
                    Usage = usage,
                    ModelUsed = invocation.ModelId
                },

                // Null together or not at all: a half-reported block would make a total that looks
                // measured and is not.
                TokensIn = reportedUsage?.InputTokenCount,
                TokensOut = reportedUsage?.OutputTokenCount,
            };
        }
        catch (Exception ex)
        {
            await _auditLog.AppendAsync(AuditEntryFor(invocation, success: false, ex.Message), ct);

            // W7G.1 Gate 7. Two fields, two audiences, and the difference between them is the whole
            // point of this member:
            //
            //   Error   - the provider's own words, kept for the operator reading this adapter's audit
            //             record. It is free text and can name a model, an endpoint or an account id.
            //   Failure - a value from the estate's closed neutral set, and the only thing above this
            //             seam reads or relays. It cannot carry vendor vocabulary even by accident,
            //             because the type admits nothing else.
            //
            // Before this member existed there was only Error, so the layer above had nothing to branch
            // on and every provider-reported failure - a timeout, a rejected key, a retired model -
            // arrived downstream as one undifferentiated category.
            // Unmeasured: the call did not complete, so no usage exists to report. That is not a zero —
            // it is the absence of a measurement, and it must not be priced as one.
            return ModelGatewayOutcome.Unmeasured(new ModelInvocationResult
            {
                Success = false,
                Error = ex.Message,
                Failure = OpenAIFailureClassifier.Classify(ex, ct),
                ModelUsed = invocation.ModelId
            });
        }
    }

    /// <summary>
    /// The Platform-shaped entry point, for consumers that only need the result.
    /// </summary>
    /// <remarks>
    /// <b>A caller using this method cannot tell an unreported usage from a reported zero</b> — Platform's
    /// <see cref="ModelUsage"/> has no way to say so. The governed path uses
    /// <see cref="InvokeReportingUsageAsync"/>; this exists because <see cref="IModelGateway"/> requires
    /// it, and it discards the distinction on purpose rather than inventing one.
    /// </remarks>
    public async Task<ModelInvocationResult> InvokeAsync(ModelInvocation invocation, CancellationToken ct = default)
        => (await InvokeReportingUsageAsync(invocation, ct).ConfigureAwait(false)).Result;

    public async IAsyncEnumerable<ModelStreamChunk> StreamAsync(
        ModelInvocation invocation,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var verdict = await _quotaPolicy.CheckAsync(invocation.Identity, invocation.ModelId, ct);
        if (!verdict.Allowed)
        {
            await _auditLog.AppendAsync(AuditEntryFor(invocation, success: false, verdict.Reason), ct);
            throw new InvalidOperationException(verdict.Reason ?? "Quota exceeded");
        }

        var streamingApiKey = await ResolveApiKeyAsync(ct);
        var chatClient = new ChatClient(model: ModelName(invocation.ModelId), apiKey: streamingApiKey);
        var messages = invocation.Messages.Select(ToOpenAIMessage).ToList();

        await foreach (var update in chatClient.CompleteChatStreamingAsync(messages, cancellationToken: ct))
        {
            foreach (var part in update.ContentUpdate)
            {
                yield return new ModelStreamChunk(part.Text, false);
            }
        }

        await _usageMeter.RecordAsync(UsageRecordFor(invocation, ModelUsage.Zero), ct);
        await _auditLog.AppendAsync(AuditEntryFor(invocation, success: true, "Streamed"), ct);

        yield return new ModelStreamChunk(string.Empty, true);
    }

    private static string ModelName(string modelId)
    {
        var separator = modelId.IndexOf(':');
        return separator >= 0 ? modelId[(separator + 1)..] : modelId;
    }

    private static ChatMessage ToOpenAIMessage(ModelMessage message) => message.Role switch
    {
        ModelRole.System => ChatMessage.CreateSystemMessage(message.Content),
        ModelRole.Assistant => ChatMessage.CreateAssistantMessage(message.Content),
        _ => ChatMessage.CreateUserMessage(message.Content)
    };

    private static UsageRecord UsageRecordFor(ModelInvocation invocation, ModelUsage usage) => new()
    {
        Identity = invocation.Identity,
        ModelId = invocation.ModelId,
        Usage = usage,
        RecordedAt = DateTimeOffset.UtcNow
    };

    private static AuditEntry AuditEntryFor(ModelInvocation invocation, bool success, string? detail) => new()
    {
        Identity = invocation.Identity,
        Action = $"model.invoke:{invocation.ModelId}",
        Success = success,
        Detail = detail,
        OccurredAt = DateTimeOffset.UtcNow
    };
}
