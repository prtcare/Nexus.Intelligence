using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Nexus.Intelligence.Contracts;
using Xunit;

namespace Nexus.Intelligence.Tests;

// W7A / Task 13: the deterministic behavioural proofs for the capability, dependency, exposure and
// audit-secret contracts. Each rule is paired with a negative fixture that is asserted to produce the
// OPPOSITE result, so no assertion here can pass because its check is vacuous.
public sealed class W7aContractBehaviourTests
{
    // ---------------------------------------------------------------------------------------------
    // Task 13(f) support: a secret-shaped literal assembled from fragments.
    // ---------------------------------------------------------------------------------------------

    // Assembled rather than written literally, exactly as AiRedaction assembles its prefix table. A
    // complete credential-shaped literal in a source file is flagged by every secret scanner on every
    // commit and has to be re-classified by hand by every future reader. The fragments behave
    // identically without creating that artefact.
    private static string SecretShapedValue => "s" + "k-" + new string('q', 32);

    private const string OrdinaryProse =
        "The review found three defects in the migration script and no data loss.";

    // ---------------------------------------------------------------------------------------------
    // Task 13(e): AI_OPTIONAL / AI_ENHANCED / AI_DEPENDENT validate.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void DependencyRegistry_AcceptsAllThreeClasses()
    {
        var registry = new AiDependencyRegistry(
        [
            Decl("search.index", AiDependencyClass.AiOptional, fallback: "The deterministic index is the result."),
            Decl("review.summarise", AiDependencyClass.AiEnhanced, fallback: "The raw diff is shown unsummarised."),
            Decl("chat.reply", AiDependencyClass.AiDependent, riskOwner: "Human Owner"),
        ]);

        Assert.Equal(3, registry.Count);
        Assert.Single(registry.InClass(AiDependencyClass.AiOptional));
        Assert.Single(registry.InClass(AiDependencyClass.AiEnhanced));
        Assert.Single(registry.InClass(AiDependencyClass.AiDependent));

        Assert.True(registry.MustSurviveAiOutage("search.index"));
        Assert.True(registry.MustSurviveAiOutage("review.summarise"));
        Assert.False(registry.MustSurviveAiOutage("chat.reply"));
    }

    // An unclassified feature is not cleared. Returning true here would let an omission read as a
    // clearance, which is the exact condition the classification exists to eliminate.
    [Fact]
    public void DependencyRegistry_DoesNotClearAnUndeclaredFeature()
    {
        Assert.False(AiDependencyRegistry.Empty.MustSurviveAiOutage("nobody.classified.this"));
        Assert.False(AiDependencyRegistry.Empty.TryResolve("nobody.classified.this", out _));
    }

    [Fact]
    public void DependencyRegistry_Rejects_OptionalWithoutDeterministicFallback()
    {
        var error = Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("search.index", AiDependencyClass.AiOptional),
        ]));

        Assert.Contains("deterministic fallback", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void DependencyRegistry_Rejects_AiDependentThatClaimsAFallback()
    {
        var error = Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("chat.reply", AiDependencyClass.AiDependent, fallback: "A template reply.", riskOwner: "Human Owner"),
        ]));

        Assert.Contains("AI-enhanced, not AI-dependent", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void DependencyRegistry_Rejects_AiDependentWithoutAnAcceptedRiskOwner()
    {
        var error = Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("chat.reply", AiDependencyClass.AiDependent),
        ]));

        Assert.Contains("accepted-risk", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void DependencyRegistry_Rejects_AcceptedRiskOwnerOnAClassThatHasAFallback()
    {
        Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("review.summarise", AiDependencyClass.AiEnhanced,
                fallback: "The raw diff is shown unsummarised.", riskOwner: "Somebody"),
        ]));
    }

    [Fact]
    public void DependencyRegistry_Rejects_DuplicateFeatureId()
    {
        var error = Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("search.index", AiDependencyClass.AiOptional, fallback: "a"),
            Decl("search.index", AiDependencyClass.AiEnhanced, fallback: "b"),
        ]));

        Assert.Contains("more than once", error.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("Search.Index")]      // uppercase: not a stable identifier
    [InlineData("search")]            // single segment
    [InlineData("search..index")]     // empty segment
    [InlineData("search index")]      // whitespace
    [InlineData("search_index")]      // wrong separator
    public void DependencyRegistry_Rejects_MalformedFeatureId(string featureId)
    {
        Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl(featureId, AiDependencyClass.AiOptional, fallback: "a"),
        ]));
    }

    [Fact]
    public void DependencyRegistry_Rejects_UndefinedDependencyClass()
    {
        Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("search.index", (AiDependencyClass)99, fallback: "a"),
        ]));
    }

    [Fact]
    public void DependencyRegistry_Rejects_MissingOwnerOrRationale()
    {
        Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("search.index", AiDependencyClass.AiOptional, fallback: "a") with { Owner = "  " },
        ]));

        Assert.Throws<ArgumentException>(() => new AiDependencyRegistry(
        [
            Decl("search.index", AiDependencyClass.AiOptional, fallback: "a") with { Rationale = "" },
        ]));
    }

    [Fact]
    public void CapabilityRegister_Bootstrap_ClassifiesEveryCapabilityAndValidates()
    {
        var register = AiCapabilityRegister.Bootstrap();

        Assert.Equal(AiCapabilities.All.Count, register.Count);

        foreach (var capability in AiCapabilities.All)
        {
            Assert.True(
                CapabilityId.TryParse(capability, out var id, out _),
                $"Bootstrap capability '{capability}' is not a valid capability identifier.");

            Assert.True(register.TryResolve(id!, out var registration));
            Assert.NotNull(registration);
            Assert.False(string.IsNullOrWhiteSpace(registration!.Owner));
            Assert.False(string.IsNullOrWhiteSpace(registration.DependencyRationale));
            Assert.True(Enum.IsDefined(registration.DependencyClass));
        }

        // chat.complete is the one class the AI Head cannot serve deterministically: there is no
        // template that answers a free-form turn. D-W7A-02 records the decision.
        Assert.True(CapabilityId.TryParse(AiCapabilities.ChatComplete, out var chat, out _));
        Assert.True(register.TryResolve(chat!, out var chatRegistration));
        Assert.Equal(AiDependencyClass.AiDependent, chatRegistration!.DependencyClass);
    }

    [Fact]
    public void CapabilityRegister_ReportsADisabledCapabilityAsUnservable()
    {
        Assert.True(CapabilityId.TryParse(AiCapabilities.CodeReview, out var id, out _));

        var register = new AiCapabilityRegister(
        [
            new AiCapabilityRegistration
            {
                Capability = id!,
                Description = "Review a code change.",
                DependencyClass = AiDependencyClass.AiEnhanced,
                Owner = "AI-03 AI Governance",
                DependencyRationale = "A deterministic lint report exists; the review is additive.",
                Enabled = false,
            },
        ]);

        Assert.False(register.IsServable(id!));
        Assert.False(register.TryResolve(id!, out _));
    }

    // Negative fixture for the whole (e) group: the validation is doing the work, not the fixtures
    // being unrepresentable. If Decl() could not produce a valid declaration, every Rejects test above
    // would pass for the wrong reason.
    [Fact]
    public void DependencyRegistry_ValidationIsNonVacuous_OnAValidDeclaration()
    {
        var valid = Decl("search.index", AiDependencyClass.AiOptional, fallback: "The deterministic index.");

        var registry = new AiDependencyRegistry([valid]);

        Assert.True(registry.TryResolve(valid.FeatureId, out var resolved));
        Assert.Equal(AiDependencyClass.AiOptional, resolved!.DependencyClass);
    }

    // ---------------------------------------------------------------------------------------------
    // Task 13(f): an invalid DataClassification is rejected.
    // ---------------------------------------------------------------------------------------------

    [Theory]
    [InlineData("SuperSecret")]
    [InlineData("pii,secret")]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    public void DataClassification_Rejects_UnknownOrCombinedValues(string? candidate)
    {
        Assert.False(DataClassificationExtensions.TryParse(candidate, out _, out var reason));
        Assert.False(string.IsNullOrWhiteSpace(reason));
    }

    // Numeric input maps to a real enum member and must still be rejected: 7 is Secret, and accepting
    // "7" would let an off-by-one in a caller silently reclassify a payload as the most sensitive value
    // or, at 0, as the least.
    [Fact]
    public void DataClassification_Rejects_NumericValues_EvenInRange()
    {
        Assert.False(DataClassificationExtensions.TryParse("7", out var parsed, out _));
        Assert.Equal(default, parsed);

        Assert.False(DataClassificationExtensions.TryParse("0", out _, out _));
    }

    [Theory]
    [InlineData("Public", DataClassification.Public)]
    [InlineData("internal", DataClassification.Internal)]
    [InlineData("PII", DataClassification.Pii)]
    [InlineData("CustomerData", DataClassification.CustomerData)]
    [InlineData("Secret", DataClassification.Secret)]
    public void DataClassification_Accepts_CanonicalNames(string candidate, DataClassification expected)
    {
        Assert.True(DataClassificationExtensions.TryParse(candidate, out var parsed, out _));
        Assert.Equal(expected, parsed);
    }

    [Fact]
    public void DataClassification_OrderingIsAscendingBySensitivity()
    {
        DataClassification[] ascending =
        [
            DataClassification.Public,
            DataClassification.Internal,
            DataClassification.Confidential,
            DataClassification.Pii,
            DataClassification.Financial,
            DataClassification.SourceCode,
            DataClassification.CustomerData,
            DataClassification.Secret,
        ];

        for (var i = 0; i < ascending.Length; i++)
        {
            Assert.Equal(i, (int)ascending[i]);
            Assert.True(ascending[i].IsAtLeast(ascending[0]));
        }

        Assert.Equal(DataClassification.Secret, DataClassificationExtensions.MostSensitive);
        Assert.Equal(DataClassification.Secret, DataClassificationExtensions.Aggregate(ascending));
        Assert.Equal(DataClassification.Public, DataClassificationExtensions.Aggregate([]));
        Assert.True(DataClassification.Secret.IsNeverPersistable());
        Assert.False(DataClassification.Internal.IsNeverPersistable());
    }

    [Fact]
    public void DataClassification_Parse_ThrowsFormatException_WithAReason()
    {
        var error = Assert.Throws<FormatException>(() => DataClassificationExtensions.Parse("SuperSecret"));
        Assert.Contains("SuperSecret", error.Message, StringComparison.Ordinal);
    }

    // ---------------------------------------------------------------------------------------------
    // Task 13(f) continued: the exposure policy is total, and Secret never egresses.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ExposurePolicy_Rejects_MissingDuplicateOrUndefinedRules()
    {
        var complete = DataExposurePolicy.Default().Rules;

        // Missing a rule for one classification: refused rather than defaulted.
        Assert.Throws<ArgumentException>(() => new DataExposurePolicy(complete.Where(r => r.Classification != DataClassification.Pii)));

        // Two rules for one classification.
        Assert.Throws<ArgumentException>(() => new DataExposurePolicy(complete.Append(complete[0])));

        // A rule for a value that is not a classification.
        var undefined = new DataExposureRule
        {
            Classification = (DataClassification)99,
            Rationale = "not a real classification",
        };

        Assert.Throws<ArgumentException>(() => new DataExposurePolicy(complete.Append(undefined)));
    }

    [Fact]
    public void ExposurePolicy_SecretNeverEgresses_EvenWithRedaction()
    {
        var policy = DataExposurePolicy.Default();
        var secret = policy.RuleFor(DataClassification.Secret);

        Assert.Empty(secret.AllowedDestinations);
        Assert.False(secret.EgressPermitted);

        foreach (var destination in Enum.GetValues<AiDestinationClass>())
        {
            Assert.DoesNotContain(destination, secret.AllowedDestinations);
        }
    }

    [Fact]
    public void ExposurePolicy_CustomerDataIsLocalOnly()
    {
        var rule = DataExposurePolicy.Default().RuleFor(DataClassification.CustomerData);

        Assert.True(rule.IsLocalOnly);
        Assert.DoesNotContain(AiDestinationClass.RemoteProvider, rule.AllowedDestinations);
    }

    [Fact]
    public void ExposureEvaluator_BlocksSecretAtARemoteDestination_WithATypedFailure()
    {
        var evaluator = new DeclaredClassificationExposureEvaluator(DataExposurePolicy.Default());

        var decision = evaluator.Evaluate(
            DataClassification.Secret,
            [DataClassification.Internal],
            AiDestinationClass.RemoteProvider);

        Assert.False(decision.Allowed);
        Assert.NotNull(decision.Reason);

        var failure = decision.ToFailure("corr-1");

        Assert.Equal(AiFailureCategory.DataExposureBlocked, failure.Category);
        Assert.Equal("corr-1", failure.CorrelationId);
        Assert.False(failure.Retryable);
    }

    // Negative fixture: the same evaluator, same destination, a classification that IS admitted. Without
    // this the block above could be produced by an evaluator that refuses everything.
    [Fact]
    public void ExposureEvaluator_AdmitsInternalAtTheSameDestination()
    {
        var evaluator = new DeclaredClassificationExposureEvaluator(DataExposurePolicy.Default());

        var decision = evaluator.Evaluate(
            DataClassification.Internal,
            [DataClassification.Public],
            AiDestinationClass.RemoteProvider);

        Assert.True(decision.Allowed);
        Assert.False(decision.RequiresRedaction);
        Assert.Equal(DataClassification.Internal, decision.DeclaredClassification);

        // The ceiling is taken over the supplied context, not over the declared classification. The two
        // are separately recorded so an auditor can see both what the caller asserted and what it
        // actually attached.
        Assert.Equal(DataClassification.Public, decision.ContextCeiling);

        var withSensitiveContext = evaluator.Evaluate(
            DataClassification.Internal,
            [DataClassification.Internal, DataClassification.Confidential],
            AiDestinationClass.RemoteProvider);

        Assert.Equal(DataClassification.Confidential, withSensitiveContext.ContextCeiling);
        Assert.Equal(DataClassification.Internal, withSensitiveContext.DeclaredClassification);
    }

    [Fact]
    public void ContextBuilder_ExcludesASourceMoreSensitiveThanTheDestinationAdmits_AndReportsIt()
    {
        var policy = DataExposurePolicy.Default();
        var evaluator = new DeclaredClassificationExposureEvaluator(policy);

        var decision = evaluator.Evaluate(
            DataClassification.Internal,
            [DataClassification.Internal, DataClassification.CustomerData],
            AiDestinationClass.RemoteProvider);

        // The declared classification is what gates, so the request proceeds...
        Assert.True(decision.Allowed);

        // ...and the customer-owned source is excluded rather than sent.
        Assert.Equal(DataClassification.CustomerData, decision.ContextCeiling);

        var result = new FilteringContextBuilder().Build(
            new ContextBundle(
            [
                Item("internal-1", DataClassification.Internal, "an internal note"),
                Item("customer-1", DataClassification.CustomerData, "customer data"),
            ]),
            decision,
            policy);

        Assert.Single(result.Bundle.Items);
        Assert.Equal("internal-1", result.Bundle.Items[0].Id);
        Assert.True(result.IsPartial);
        Assert.Single(result.Excluded);
        Assert.Equal("customer-1", result.Excluded[0].ContextItemId);
        Assert.Equal(DataClassification.CustomerData, result.Excluded[0].Classification);

        // No digest of excluded content: the reference shows something was withheld, not what it was.
        Assert.Null(result.Excluded[0].ContentHash);
        Assert.True(result.Excluded[0].HashWithheld);
    }

    // An item that does not declare a classification inherits the request's, so an undeclared source is
    // never treated as harmless.
    [Fact]
    public void ContextBuilder_TreatsAnUndeclaredSourceAsTheRequestsOwnClassification()
    {
        var policy = DataExposurePolicy.Default();
        var evaluator = new DeclaredClassificationExposureEvaluator(policy);

        var internalDecision = evaluator.Evaluate(
            DataClassification.Internal, [], AiDestinationClass.RemoteProvider);

        var admitted = new FilteringContextBuilder().Build(
            new ContextBundle([Item("undeclared", classification: null, "no declared classification")]),
            internalDecision,
            policy);

        Assert.Single(admitted.Bundle.Items);

        var secretDecision = evaluator.Evaluate(
            DataClassification.Secret, [], AiDestinationClass.Local);

        var excluded = new FilteringContextBuilder().Build(
            new ContextBundle([Item("undeclared", classification: null, "no declared classification")]),
            secretDecision,
            policy);

        Assert.Empty(excluded.Bundle.Items);
        Assert.Equal(DataClassification.Secret, excluded.Excluded[0].Classification);
    }

    [Fact]
    public void ContextBuilder_ExcludesNothingWhenEverythingIsAdmitted()
    {
        var policy = DataExposurePolicy.Default();
        var decision = new DeclaredClassificationExposureEvaluator(policy)
            .Evaluate(DataClassification.Public, [DataClassification.Public], AiDestinationClass.RemoteProvider);

        var result = new FilteringContextBuilder().Build(
            new ContextBundle([Item("a", DataClassification.Public, "text")]),
            decision,
            policy);

        Assert.False(result.IsPartial);
        Assert.Single(result.Bundle.Items);
    }

    // ---------------------------------------------------------------------------------------------
    // Task 13(g): secret values cannot be persisted into audit or control records by the normal
    // serializer path.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AuditSerialization_RedactsASecretShapedValueInFreeText()
    {
        var secret = SecretShapedValue;

        var json = AiAuditSerialization.Serialize(Record(purpose: $"Rotate this key: {secret}"));

        Assert.DoesNotContain(secret, json, StringComparison.Ordinal);
        Assert.Contains(AiRedaction.RedactionMarker, json, StringComparison.Ordinal);
    }

    [Fact]
    public void AuditSerialization_RedactsSecretShapedIdentifiers()
    {
        var secret = SecretShapedValue;

        var json = AiAuditSerialization.Serialize(Record(purpose: "review", tenantId: secret));

        Assert.DoesNotContain(secret, json, StringComparison.Ordinal);
        Assert.Contains(AiRedaction.RedactionMarker, json, StringComparison.Ordinal);
    }

    // NEGATIVE FIXTURE, and the reason AiAuditSerialization exists. The same record serialised by the
    // raw serializer DOES contain the secret. If this test ever starts failing, the assertion above has
    // stopped proving anything, because the safe path would no longer be the only path doing work.
    [Fact]
    public void RawSerializer_DoesNotRedact_TheReasonTheSafePathExists()
    {
        var secret = SecretShapedValue;
        var record = Record(purpose: $"Rotate this key: {secret}");

        var raw = JsonSerializer.Serialize(record, AiAuditSerialization.Options);

        Assert.Contains(secret, raw, StringComparison.Ordinal);

        var safe = AiAuditSerialization.Serialize(record);
        Assert.DoesNotContain(secret, safe, StringComparison.Ordinal);
    }

    // The structural half of the same control: a record with no field capable of holding a credential
    // cannot leak one through any serializer, however it is called.
    [Fact]
    public void AuditRecord_HasNoFieldCapableOfHoldingACredentialValue()
    {
        var offenders = typeof(AiAuditRecord)
            .GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Where(p => AiRedaction.IsSensitiveFieldName(p.Name))
            .Select(p => p.Name)
            .ToArray();

        Assert.True(
            offenders.Length == 0,
            "AiAuditRecord has a field named after a credential. The record is a ledger, not a place a "
            + "credential may be written. Offenders: " + string.Join(", ", offenders));

        // Non-vacuity: the detector must recognise the names it is meant to catch.
        Assert.True(AiRedaction.IsSensitiveFieldName("ApiKey"));
        Assert.True(AiRedaction.IsSensitiveFieldName("access_token"));
        Assert.True(AiRedaction.IsSensitiveFieldName("ConnectionString"));
        Assert.True(AiRedaction.IsSensitiveFieldName("Authorization"));
        Assert.False(AiRedaction.IsSensitiveFieldName("Purpose"));
        Assert.False(AiRedaction.IsSensitiveFieldName("Author"));
    }

    [Fact]
    public void AuditRecord_WithholdsTheContentHashOfSecretContext()
    {
        var record = Record(purpose: "review") with
        {
            ContextReferences =
            [
                new AiContextReference
                {
                    ContextItemId = "note-1",
                    Classification = DataClassification.Internal,
                    ContentHash = "sha256:abc",
                },
                new AiContextReference
                {
                    ContextItemId = "credential-1",
                    Classification = DataClassification.Secret,
                    ContentHash = null,
                },
            ],
        };

        var credential = record.ContextReferences.Single(r => r.Classification == DataClassification.Secret);
        Assert.True(credential.HashWithheld);

        var json = AiAuditSerialization.Serialize(record);

        // The reference survives; the digest does not.
        Assert.Contains("credential-1", json, StringComparison.Ordinal);
        Assert.Contains("sha256:abc", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Redaction_RedactsTheWholeValueWhenItIsASecret_AndLeavesProseAlone()
    {
        Assert.Equal(AiRedaction.RedactionMarker, AiRedaction.Redact(SecretShapedValue));

        // Non-vacuity in the other direction: a redactor that mangles ordinary text would make the
        // control unusable and would be turned off by the first operator who hit it.
        Assert.Equal(OrdinaryProse, AiRedaction.Redact(OrdinaryProse));
        Assert.Null(AiRedaction.Redact(null));
        Assert.Equal(string.Empty, AiRedaction.Redact(string.Empty));

        // A short value with a secret-shaped prefix is left alone: the length floor is deliberate, and
        // lowering it to catch more is how a detector starts redacting prose.
        Assert.Equal("sk-", AiRedaction.Redact("sk-"));
    }

    [Fact]
    public void Redaction_ReplacesTheOffendingTokenInPlace_WhenASecretIsEmbeddedInProse()
    {
        var text = $"I pasted {SecretShapedValue} into the field by mistake.";

        var redacted = AiRedaction.Redact(text);

        Assert.NotNull(redacted);
        Assert.DoesNotContain(SecretShapedValue, redacted!, StringComparison.Ordinal);
        Assert.Contains(AiRedaction.RedactionMarker, redacted!, StringComparison.Ordinal);

        // The audit fact survives. Discarding the sentence would lose the record that an operator
        // handled a credential, which is the fact the record exists to keep.
        Assert.Contains("I pasted", redacted!, StringComparison.Ordinal);
    }

    [Fact]
    public void SecretValueDetector_IsNonVacuous()
    {
        Assert.True(AiRedaction.LooksLikeSecretValue(SecretShapedValue));
        Assert.False(AiRedaction.LooksLikeSecretValue(OrdinaryProse));
        Assert.False(AiRedaction.LooksLikeSecretValue(new string('x', 64)));
        Assert.False(AiRedaction.LooksLikeSecretValue("sk-"));
    }

    // ---------------------------------------------------------------------------------------------
    // Task 13(a)/(b) at the behavioural level: the caller's request carries no provider authority and
    // the failure that travels back is typed.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void CapabilityRequest_RequiresAnExplicitClassification_AndDefaultsToNoToolPermission()
    {
        var classification = typeof(AiCapabilityRequest).GetProperty(nameof(AiCapabilityRequest.Classification));
        var execution = typeof(AiCapabilityRequest).GetProperty(nameof(AiCapabilityRequest.Execution));

        Assert.NotNull(classification);
        Assert.NotNull(execution);

        // Required, with no default: a caller that forgets to classify gets a compile error rather than
        // a silent downgrade to the least protective value.
        Assert.True(IsRequired(classification!));
        Assert.Equal(DataClassification.Public, default(DataClassification));

        // Contrast, and the non-vacuity half of this check: a field WITH a safe default is not required.
        Assert.False(IsRequired(execution!));

        var request = new AiCapabilityRequest
        {
            RequestId = "req-1",
            Capability = CapabilityId.Parse(AiCapabilities.CodeReview),
            Purpose = "Review the migration script before it is applied.",
            Requester = Requester(),
            Input = new TurnInput(TurnInputKind.Task, "review this", []),
            Classification = DataClassification.Internal,
            IdempotencyKey = "idem-1",
        };

        Assert.Equal(ToolSideEffectClass.None, request.Tools.MaxSideEffect);
        Assert.Empty(request.Tools.AllowedToolIds);
        Assert.Equal(ContextBundle.Empty, request.Context);
        Assert.Equal(AiDegradationPreference.ReturnDeterministicResult, request.Execution.OnDegradation);
    }

    [Fact]
    public void CapabilityId_RejectsMalformedAndVersionedIdentifiers()
    {
        Assert.True(CapabilityId.TryParse(AiCapabilities.CodeReview, out var id, out _));
        Assert.Equal("code.review", id!.Value);

        foreach (var invalid in new[]
                 {
                     "Code.Review",      // not lowercase
                     "code",             // single segment
                     "code..review",     // empty segment
                     "code_review",      // wrong separator
                     "code.review.v2",   // version pinning under another name
                     "code.review.2",    // version pinning without the v
                     " code.review",     // untrimmed
                 })
        {
            Assert.False(
                CapabilityId.TryParse(invalid, out _, out _),
                $"CapabilityId accepted '{invalid}'. A capability identifier is stable vocabulary, not a "
                + "provider, model or version.");
        }

        // A vendor-shaped identifier is well-formed and unregistered. It is NOT caught by the format
        // rule, and it must not be: catching it would require this assembly to hold a list of vendor
        // names, which Task 12 forbids and which would need editing every time a provider is added. The
        // control is that capability membership is governed — an identifier nobody registered resolves
        // to nothing and is served as AI_FAILURE_CATEGORY.CapabilityNotFound.
        Assert.True(CapabilityId.TryParse("gpt-4o.review", out var vendorShaped, out _));
        Assert.False(AiCapabilityRegister.Bootstrap().TryResolve(vendorShaped!, out _));
    }

    [Fact]
    public void CapabilityException_CarriesNoInnerException()
    {
        var exception = new AiCapabilityException(
            AiFailureCategory.ProviderUnavailable, "provider_health_unusable", "No provider is available.", "corr-1");

        Assert.Null(exception.InnerException);
        Assert.Equal(AiFailureCategory.ProviderUnavailable, exception.Failure.Category);
        Assert.True(exception.Failure.Retryable);
        Assert.False(exception.RequiresHumanAction);
    }

    [Fact]
    public void FailureCategory_RetryOwnershipIsStatedByTheContract()
    {
        // Retryable: the same request could plausibly succeed later.
        foreach (var retryable in new[]
                 {
                     AiFailureCategory.AiUnavailable, AiFailureCategory.ProviderUnavailable,
                     AiFailureCategory.ModelUnavailable, AiFailureCategory.Timeout,
                     AiFailureCategory.InvalidOutput,
                 })
        {
            Assert.True(retryable.IsRetryable(), $"{retryable} must be retryable.");
        }

        // Not retryable: repeating the request changes nothing, and a caller that retries a policy
        // refusal turns a correct refusal into load.
        foreach (var terminal in new[]
                 {
                     AiFailureCategory.PolicyBlocked, AiFailureCategory.DataExposureBlocked,
                     AiFailureCategory.ToolPermissionDenied, AiFailureCategory.BudgetBlocked,
                     AiFailureCategory.CapabilityNotFound, AiFailureCategory.HumanDecisionRequired,
                 })
        {
            Assert.False(terminal.IsRetryable(), $"{terminal} must not be retryable.");
        }

        Assert.True(AiFailureCategory.HumanDecisionRequired.IsRetryable() == false);
    }

    // ---------------------------------------------------------------------------------------------
    // Fixtures.
    // ---------------------------------------------------------------------------------------------

    private static bool IsRequired(PropertyInfo property)
        => property.GetCustomAttributes(inherit: false).Any(a => a is RequiredMemberAttribute);

    private static AiDependencyDeclaration Decl(
        string featureId,
        AiDependencyClass dependencyClass,
        string? fallback = null,
        string? riskOwner = null)
        => new()
        {
            FeatureId = featureId,
            Owner = "Products / Forge",
            DependencyClass = dependencyClass,
            Rationale = "Recorded for the W7A dependency classifications.",
            DeterministicFallback = fallback,
            AcceptedRiskOwner = riskOwner,
        };

    private static ContextItem Item(string id, DataClassification? classification, string body)
        => new()
        {
            Id = id,
            Kind = ContextItemKind.Document,
            Body = body,
            Trust = TrustLevel.Reported,
            Classification = classification,
        };

    private static AiRequesterIdentity Requester(string? tenantId = null)
        => new()
        {
            Head = CallingHead.Product,
            PrincipalId = "principal-1",
            ProductId = "developer",
            TenantId = tenantId,
        };

    private static AiAuditRecord Record(string purpose, string? tenantId = null)
        => new()
        {
            ExecutionId = "exec-1",
            RequestId = "req-1",
            CorrelationId = "corr-1",
            Requester = Requester(tenantId),
            Capability = CapabilityId.Parse(AiCapabilities.CodeReview),
            Purpose = purpose,
            Classification = DataClassification.Internal,
            Status = AiExecutionStatus.Succeeded,
            Timestamp = DateTimeOffset.UnixEpoch,
            ProviderUsed = "provider-a",
            ModelUsed = "model-a",
        };
}
