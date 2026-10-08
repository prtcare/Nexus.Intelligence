using System;
using System.Collections.Generic;
using System.ClientModel;
using System.ClientModel.Primitives;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Models;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Providers.OpenAI;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7G.1 TASK 1: the two properties of the provider failure seam that no single execution can prove.
//
// The behaviour of the seam - that a classified failure arrives at a caller as the right category - is
// proved in Nexus.Intelligence.Tests by running governed turns. What cannot be proved by running a turn
// is stated here, because both are properties of the DECLARATIONS rather than of any execution:
//
//   1. The two enumerations are the same failure set, member for member, value for value. This is what
//      makes the drift guard in ModelFailureMap a compile-time obligation rather than a convention: a
//      member added to one vocabulary and not the other fails HERE, in a test whose only job is to say so.
//
//   2. The vendor's vocabulary is converted by a pure function of an exception's TYPE and STATUS, and
//      never by reading its text. This is what lets the whole mapping be proved with no network and no
//      credential - and, more importantly, it is what stops the message channel being reopened by a
//      classifier that pattern-matched on vendor prose.
//
// WHY THE FAKE PIPELINE RESPONSE EXISTS. The SDK's ClientResultException takes its status from the
// transport response it wraps, and there is no constructor that accepts a bare status code. Without a
// response the exception reports status 0, so every status row would collapse into the default and the
// interesting rows - 401, 403, 429, 404 - would be unprovable. The fake below supplies exactly what
// ClientResultException reads and nothing else, which keeps these tests deterministic and offline.
public sealed class W7g1ProviderFailureSeamTests
{
    /// <summary>
    /// The two spellings of the failure set declare the same members at the same values.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>This is the assertion that keeps the duplication safe.</b> The two vocabularies cannot be one
    /// type: the Platform boundary guard forbids a <c>Nexus.Platform.*</c> assembly from depending on
    /// <c>Nexus.Intelligence.*</c>, so the cross-repository contract cannot name the AI Head's enum, and
    /// the AI Head cannot put its own enum on a Platform type. The duplication is therefore forced by the
    /// boundary rather than chosen - which makes the correspondence between the spellings the thing that
    /// must be mechanically checked, because nothing about the type system will check it.
    /// </para>
    /// <para>
    /// <b>Names and values are both compared, in order.</b> Comparing names alone would let a member be
    /// inserted in the middle of one enum and shift every value after it, so that two spellings agreeing
    /// on spelling disagreed on the wire. Comparing the value sequence catches that, and catches a
    /// renumbering that would silently reinterpret a persisted classification.
    /// </para>
    /// <para>
    /// <b>This guard is deliberately the strictest form: exact equality, not a containment check.</b> A
    /// member added to the seam vocabulary for a condition this estate has no category for must fail here
    /// rather than be quietly dropped to the mapping's default, because that is precisely the moment a
    /// decision is owed.
    /// </para>
    /// </remarks>
    [Fact]
    public void TheTwoSpellings_DeclareTheSameFailureSet_MemberForMemberAndValueForValue()
    {
        var seam = Enum.GetValues<ModelFailureKind>()
            .Select(kind => (kind.ToString(), (int)kind))
            .ToArray();

        var head = Enum.GetValues<AiFailureCategory>()
            .Select(category => (category.ToString(), (int)category))
            .ToArray();

        Assert.Equal(head, seam);

        // Non-vacuity floor. Everything above would pass on two empty enums, and an "equal" that is
        // equal because both sides vanished is the failure mode this line exists to rule out.
        Assert.Equal(12, seam.Length);
    }

    /// <summary>
    /// Every member of the seam vocabulary maps to the category of the same name.
    /// </summary>
    /// <remarks>
    /// The correspondence above is about declarations; this one is about behaviour, and it is the reason
    /// the mapping is written as an explicit switch rather than a cast. A cast would compile only while
    /// the two enums happened to line up, and would convert a divergence into a silent reinterpretation.
    /// The switch makes divergence a compile error, and this test states the outcome for every row.
    /// </remarks>
    [Theory]
    [InlineData(ModelFailureKind.AiUnavailable, AiFailureCategory.AiUnavailable)]
    [InlineData(ModelFailureKind.ProviderUnavailable, AiFailureCategory.ProviderUnavailable)]
    [InlineData(ModelFailureKind.ModelUnavailable, AiFailureCategory.ModelUnavailable)]
    [InlineData(ModelFailureKind.PolicyBlocked, AiFailureCategory.PolicyBlocked)]
    [InlineData(ModelFailureKind.DataExposureBlocked, AiFailureCategory.DataExposureBlocked)]
    [InlineData(ModelFailureKind.ToolPermissionDenied, AiFailureCategory.ToolPermissionDenied)]
    [InlineData(ModelFailureKind.BudgetBlocked, AiFailureCategory.BudgetBlocked)]
    [InlineData(ModelFailureKind.Timeout, AiFailureCategory.Timeout)]
    [InlineData(ModelFailureKind.InvalidOutput, AiFailureCategory.InvalidOutput)]
    [InlineData(ModelFailureKind.CapabilityNotFound, AiFailureCategory.CapabilityNotFound)]
    [InlineData(ModelFailureKind.HumanDecisionRequired, AiFailureCategory.HumanDecisionRequired)]
    public void EverySeamMember_MapsToTheCategoryOfTheSameName(
        ModelFailureKind kind,
        AiFailureCategory expected)
    {
        Assert.Equal(expected, ModelFailureMap.ToCategory(kind));
    }

    /// <summary>
    /// An absent or unmapped classification becomes an unavailability, never a terminal refusal.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The two spellings of "we do not know" both land on <see cref="AiFailureCategory.ProviderUnavailable"/>
    /// rather than on <see cref="AiFailureCategory.Unspecified"/>. The reasoning is behavioural and the
    /// obvious mapping is the dangerous one: <c>Unspecified</c> is not retryable and is not an
    /// unavailability, so routing an unclassified provider failure there would tell the failover plane
    /// that a provider outage is a deterministic refusal, and would tell an
    /// <see cref="AiDependencyClass.AiEnhanced"/> caller that it must not degrade to its deterministic
    /// path. A recoverable outage would become a terminal, caller-visible refusal.
    /// </para>
    /// <para>
    /// <b>The null row is the backward-compatibility guarantee.</b> Every adapter in the estate that has
    /// not been updated to classify its failures produces null, so this row is what makes the whole
    /// change additive: an un-updated adapter behaves exactly as it did before the member existed.
    /// </para>
    /// </remarks>
    [Theory]
    [InlineData(null)]
    [InlineData(ModelFailureKind.Unspecified)]
    public void AnAbsentOrUnmappedClassification_BecomesAnUnavailability(ModelFailureKind? kind)
    {
        var category = ModelFailureMap.ToCategory(kind);

        Assert.Equal(AiFailureCategory.ProviderUnavailable, category);

        // Retryable and an unavailability: the two properties that keep the failover plane and a
        // degrading caller behaving as they did before this member existed.
        Assert.True(category.IsRetryable());
        Assert.True(category.IsUnavailability());
    }

    /// <summary>
    /// A cancelled invocation is a timeout, whether or not the caller's token was the cause.
    /// </summary>
    /// <remarks>
    /// Both halves matter. The first is an invocation the caller abandoned; the second is the transport
    /// giving up on its own deadline, which surfaces as an
    /// <see cref="OperationCanceledException"/> whose token was never cancelled. A classifier that
    /// branched on <c>ct.IsCancellationRequested</c> would classify the second as a caller cancellation
    /// and lose it, so the token is carried for explanation and not for the decision.
    /// </remarks>
    [Fact]
    public void ACancelledInvocation_IsATimeout_EvenWhenTheCallersTokenWasNotTheCause()
    {
        using var abandoned = new CancellationTokenSource();
        abandoned.Cancel();

        Assert.Equal(
            ModelFailureKind.Timeout,
            OpenAIFailureClassifier.Classify(new OperationCanceledException(), abandoned.Token));

        Assert.Equal(
            ModelFailureKind.Timeout,
            OpenAIFailureClassifier.Classify(new OperationCanceledException(), CancellationToken.None));

        Assert.Equal(
            ModelFailureKind.Timeout,
            OpenAIFailureClassifier.Classify(
                new TaskCanceledException("The request was canceled due to the configured HttpClient.Timeout of 100 seconds elapsing."),
                CancellationToken.None));
    }

    /// <summary>
    /// Failures that never reached a provider decision are classified by their type alone.
    /// </summary>
    /// <remarks>
    /// These three carry no SDK error envelope and no status, so their type is the only fact available -
    /// which is the point of classifying by type: a transport failure and an unreadable body are
    /// distinguishable without consulting anything the vendor wrote.
    /// </remarks>
    [Fact]
    public void ATransportFailure_AndAnUnreadableBody_AreClassifiedByType()
    {
        Assert.Equal(
            ModelFailureKind.ProviderUnavailable,
            OpenAIFailureClassifier.Classify(
                new HttpRequestException("No such host is known. (api.openai.com:443)"),
                CancellationToken.None));

        Assert.Equal(
            ModelFailureKind.InvalidOutput,
            OpenAIFailureClassifier.Classify(
                new JsonException("The JSON value could not be converted to ModelMessage."),
                CancellationToken.None));
    }

    /// <summary>
    /// An SDK error envelope is classified by its status, across every row the vocabulary has a target
    /// for and one it does not.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>The three authentication-and-rate-limit rows are the substance.</b> 401 and 403 read like a
    /// policy block and are mapped to an unavailability on purpose: a credential one provider rejects is
    /// a fact about that provider, and the estate's remedy is to fail over to a provider holding its own
    /// working credential. Mapping them to <see cref="ModelFailureKind.PolicyBlocked"/> - which is not
    /// retryable - would convert one misconfigured key into a total outage for every capability routed
    /// through that provider, and would do it while looking like a correct, conservative mapping.
    /// </para>
    /// <para>
    /// <b>400 is here to keep the default row honest.</b> A malformed request has no target in the closed
    /// set, and the classifier says so instead of forcing it into a neighbouring member.
    /// </para>
    /// </remarks>
    [Theory]
    [InlineData(408, ModelFailureKind.Timeout)]
    [InlineData(401, ModelFailureKind.ProviderUnavailable)]
    [InlineData(403, ModelFailureKind.ProviderUnavailable)]
    [InlineData(429, ModelFailureKind.ProviderUnavailable)]
    [InlineData(404, ModelFailureKind.ModelUnavailable)]
    [InlineData(500, ModelFailureKind.ProviderUnavailable)]
    [InlineData(503, ModelFailureKind.ProviderUnavailable)]
    [InlineData(400, ModelFailureKind.Unspecified)]
    public void AnSdkErrorEnvelope_IsClassifiedByItsStatus(int status, ModelFailureKind expected)
    {
        var exception = new ClientResultException(
            "OpenAI returned an error for model gpt-4o in organization org-abc123 at https://api.openai.com/v1.",
            new ScriptedPipelineResponse(status));

        Assert.Equal(expected, OpenAIFailureClassifier.Classify(exception, CancellationToken.None));
    }

    /// <summary>
    /// The status table is total over the statuses a transport can report.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Swept rather than sampled, because the rows that matter here are the ones nobody thought to write:
    /// the <c>&gt;= 500</c> arm has to hold across the whole 5xx range rather than at the three statuses a
    /// test would naturally name, and every 4xx the table does not name has to fall to the default rather
    /// than to a neighbouring row.
    /// </para>
    /// <para>
    /// The default is asserted as <see cref="ModelFailureKind.Unspecified"/> rather than as "anything",
    /// because a default that guessed would be indistinguishable to a reader from an observed category.
    /// </para>
    /// </remarks>
    [Fact]
    public void TheStatusTable_IsTotal_AndItsSpansHoldAcrossTheirWholeRange()
    {
        Assert.Equal(ModelFailureKind.Timeout, OpenAIFailureClassifier.FromStatus(408));

        foreach (var status in new[] { 401, 403, 429 })
        {
            Assert.Equal(ModelFailureKind.ProviderUnavailable, OpenAIFailureClassifier.FromStatus(status));
        }

        Assert.Equal(ModelFailureKind.ModelUnavailable, OpenAIFailureClassifier.FromStatus(404));

        foreach (var status in Enumerable.Range(500, 100))
        {
            Assert.Equal(ModelFailureKind.ProviderUnavailable, OpenAIFailureClassifier.FromStatus(status));
        }

        // Every status the table does not name: the informational and redirect ranges, the 4xx codes that
        // sit either side of the ones it does name - 402, 409, 422, 451 - and, deliberately, every status
        // outside the 5xx span the previous loop already covered.
        var unmapped = Enumerable.Range(100, 500)
            .Where(status => status is not (401 or 403 or 404 or 408 or 429))
            .Where(status => status is not (>= 500 and <= 599));

        Assert.All(unmapped, status =>
            Assert.Equal(ModelFailureKind.Unspecified, OpenAIFailureClassifier.FromStatus(status)));
    }

    /// <summary>
    /// No vendor vocabulary survives classification, whatever the vendor wrote.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>This is the directive's "must not leak a vendor exception", stated as an invariant over the
    /// output rather than as an assertion about one input.</b> The exception handed in here is laden with
    /// everything a real one carries - a model name, an organization identifier, an API key prefix, an
    /// endpoint - and the assertion is that none of it appears in the classification that comes out. An
    /// enum cannot carry it, which is the structural reason an enum was chosen over widening the free-text
    /// field: this property is enforced by the type, so it holds for vendor messages nobody has written
    /// yet.
    /// </para>
    /// <para>
    /// The second half is the sharper one. It proves the classification is a function of type and status
    /// <em>only</em>, by handing the classifier two envelopes with identical type and status but wildly
    /// different text - one naming a provider, one empty - and requiring the same answer. A classifier
    /// that had begun pattern-matching on vendor prose would pass the first assertion and fail this one.
    /// </para>
    /// </remarks>
    [Fact]
    public void NoVendorVocabulary_SurvivesClassification()
    {
        string[] vendorTokens =
        [
            "OpenAI", "Azure", "Anthropic", "Gemini", "gpt-4o", "org-", "sk-proj-", "api.openai.com",
            "Bearer", "Exception",
        ];

        var laden = new ClientResultException(
            "Incorrect API key provided: sk-proj-SECRETVALUE. You can find your API key at "
                + "https://platform.openai.com/account/api-keys. Request id req_abc123, organization org-abc123, "
                + "model gpt-4o, endpoint https://api.openai.com/v1/chat/completions.",
            new ScriptedPipelineResponse(429));

        var classified = OpenAIFailureClassifier.Classify(laden, CancellationToken.None);
        var rendered = classified.ToString();

        Assert.All(vendorTokens, token =>
            Assert.DoesNotContain(token, rendered, StringComparison.OrdinalIgnoreCase));

        // The classification is the same one an empty message produces. Type and status decided it; the
        // text was never read.
        var silent = new ClientResultException(string.Empty, new ScriptedPipelineResponse(429));

        Assert.Equal(classified, OpenAIFailureClassifier.Classify(silent, CancellationToken.None));

        // And the mapped category carries no vendor vocabulary either, since it is what a caller and an
        // operator actually read.
        Assert.All(vendorTokens, token =>
            Assert.DoesNotContain(
                token,
                ModelFailureMap.ToCategory(classified).ToString(),
                StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// The classifier refuses to classify nothing.
    /// </summary>
    /// <remarks>
    /// A null exception is a calling defect, not a failure condition, and answering it with an
    /// unavailability would turn "this adapter has a bug" into "the provider is down" - which is a
    /// retryable answer to a problem no retry will fix.
    /// </remarks>
    [Fact]
    public void Classify_RejectsANullException_RatherThanNamingAFailure()
    {
        Assert.Throws<ArgumentNullException>(
            () => OpenAIFailureClassifier.Classify(null!, CancellationToken.None));
    }

    /// <summary>
    /// The minimum a <see cref="ClientResultException"/> reads from its transport response.
    /// </summary>
    /// <remarks>
    /// Only the status is meaningful; everything else is present to satisfy the abstract base and is
    /// never consulted by the classifier, which reads the status and nothing else. Keeping this fake in
    /// the test assembly is what makes the SDK rows provable offline.
    /// </remarks>
    private sealed class ScriptedPipelineResponse(int status) : PipelineResponse
    {
        public override int Status => status;

        public override string ReasonPhrase => "Scripted";

        public override Stream? ContentStream { get; set; }

        public override BinaryData Content => BinaryData.FromString(string.Empty);

        protected override PipelineResponseHeaders HeadersCore => new EmptyResponseHeaders();

        public override BinaryData BufferContent(CancellationToken cancellationToken = default)
            => BinaryData.FromString(string.Empty);

        public override ValueTask<BinaryData> BufferContentAsync(CancellationToken cancellationToken = default)
            => new(BinaryData.FromString(string.Empty));

        public override void Dispose()
        {
        }
    }

    /// <summary>No headers, because the classifier reads none.</summary>
    private sealed class EmptyResponseHeaders : PipelineResponseHeaders
    {
        public override bool TryGetValue(string name, out string? value)
        {
            value = null;
            return false;
        }

        public override bool TryGetValues(string name, out IEnumerable<string>? values)
        {
            values = null;
            return false;
        }

        public override IEnumerator<KeyValuePair<string, string>> GetEnumerator()
            => Enumerable.Empty<KeyValuePair<string, string>>().GetEnumerator();
    }
}
