using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Tests.Turns;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Operations;

// W7E TASK 8, TASK 9 and TASK 10: the audit emitter, the operational read surface, and the
// reconciliation between the turn trace and the audit record.
//
// WHY THE AUDIT TESTS ARE ABOUT SHAPE AS WELL AS CONTENT. TASK 8 says a record must never carry a
// credential value, raw secret material or unnecessarily duplicated sensitive context. "We did not
// put a secret in it" is not testable by running a benign execution. So the guarantee is asserted in
// three places: the record's own properties cannot name a sensitive field, the emitter sanitizes on
// the way out, and the serializer sanitizes again even when handed a record built by hand.
public sealed class W7eAuditAndObservabilityTests
{
    // ---------------------------------------------------------------------------------------------
    // 1. The audit record is emitted, once, for a governed execution.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AGovernedExecution_EmitsExactlyOneAuditRecord()
    {
        var path = GovernedPath.Compose(TwoRoutes(tokensIn: 120, tokensOut: 40));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));

        // TASK 8's first line: before W7E, AiAuditRecord existed and was never constructed. One is now
        // written per execution, and one is the count - a second would be a second source of truth.
        Assert.Equal(1, path.Audit.Count);

        var reference = Assert.IsType<string>(outcome.AuditReference);
        var record = path.Audit.Find(reference);

        Assert.NotNull(record);
        Assert.Equal(reference, record!.ExecutionId);
    }

    [Fact]
    public void TheAuditRecord_CarriesTheEvidenceTheDirectiveNames()
    {
        var path = GovernedPath.Compose(TwoRoutes(tokensIn: 120, tokensOut: 40));

        var outcome = Run(path);
        var record = path.Audit.Find(outcome.AuditReference!)!;

        // Identity and scope, as the request stated them.
        Assert.Equal("req-w7d", record.RequestId);
        Assert.Equal("corr-w7d", record.CorrelationId);
        Assert.Equal(AiCapabilities.ChatComplete, record.Capability.Value);
        Assert.Equal("user-w7d", record.Requester.PrincipalId);
        Assert.Equal(DataClassification.Internal, record.Classification);
        Assert.False(string.IsNullOrWhiteSpace(record.Purpose));

        // What served it, from the router's selection rather than from anything the caller said.
        Assert.Equal(PrimaryProvider, record.ProviderUsed);
        Assert.Equal(PrimaryModel, record.ModelUsed);

        // What it consumed and what it cost. The fixture's models are unpriced, so the cost is absent
        // rather than zero: a zero would be an assertion that the call was free.
        Assert.Equal(120, record.Usage.InputTokens);
        Assert.Equal(40, record.Usage.OutputTokens);
        Assert.Null(record.Cost);

        // How it ended, and what governance concluded.
        Assert.Equal(AiExecutionStatus.Succeeded, record.Status);
        Assert.Null(record.FailureCategory);
        Assert.True(record.PolicyDecision!.Allowed);

        // Latency, where measured.
        Assert.NotNull(record.Timing);
    }

    [Fact]
    public void TheAuditRecord_IsWrittenOnTheRefusalPathToo()
    {
        // The record a lane most needs is the one for the execution that did not run. A sink written
        // only on the success path would leave every refusal unaccountable - and the refusal paths are
        // exactly the ones an auditor asks about.
        var path = GovernedPath.Compose(TwoRoutes(providerApproval: "Suspended"));

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));
        Assert.Equal(1, path.Audit.Count);

        var record = path.Audit.Find(outcome.AuditReference!)!;

        // No provider served it, so none is named. The record says so by its status rather than by
        // naming a route that was never reached.
        Assert.NotEqual(AiExecutionStatus.Succeeded, record.Status);
        Assert.Null(record.ProviderUsed);
        Assert.Null(record.ModelUsed);
    }

    [Fact]
    public void AFailedAndFailedOverExecution_RecordsBothRoutes()
    {
        var path = GovernedPath.Compose(TwoRoutes(failingModels: [PrimaryModel], tokensIn: 10, tokensOut: 5));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome));

        var record = path.Audit.Find(outcome.AuditReference!)!;

        // The record names the route that served the request - the fallback - and the failover record
        // names the one that did not. Neither is derived from the other, which is what makes them
        // evidence rather than a restatement.
        Assert.Equal(AlternateProvider, record.ProviderUsed);
        Assert.Equal(AlternateModel, record.ModelUsed);

        var failover = outcome.Failover!;
        Assert.True(failover.UsedFallback);
        Assert.Contains(failover.Attempts, attempt => attempt.ModelId == PrimaryModel);
    }

    // ---------------------------------------------------------------------------------------------
    // 2. A secret cannot enter an audit record.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheAuditRecord_CannotNameASensitiveField()
    {
        // TASK 8's structural guarantee, asserted by reflection rather than by inspection. A field
        // named for a credential would be a field a provider SDK could populate, and the estate's own
        // field-name heuristic is what decides what counts as one - so the check and the heuristic
        // cannot drift.
        var properties = typeof(AiAuditRecord)
            .GetProperties(BindingFlags.Public | BindingFlags.Instance);

        Assert.NotEmpty(properties);

        var sensitive = properties
            .Where(property => AiRedaction.IsSensitiveFieldName(property.Name))
            .Select(property => property.Name)
            .ToArray();

        Assert.True(
            sensitive.Length == 0,
            $"The audit record must have no credential-shaped field, and these are: {string.Join(", ", sensitive)}.");

        // NON-VACUITY: the heuristic is not returning false for everything. If it were, the assertion
        // above would hold on any record shape at all, including one with a field called ApiKey.
        Assert.True(AiRedaction.IsSensitiveFieldName("ApiKey"));
        Assert.True(AiRedaction.IsSensitiveFieldName("Authorization"));
    }

    [Fact]
    public void Serialization_RedactsASecretTypedIntoAFreeTextField()
    {
        // A record built by hand, because that is the only way to state this claim: the emitter will
        // not produce one. The free-text fields are the ones a person writes, and a person can paste a
        // credential into any of them - which is the reason the backstop exists.
        var record = Record(purpose: $"Pasted {Secret()} into the purpose box.");

        var json = AiAuditSerialization.Serialize(record);

        Assert.DoesNotContain(Secret(), json, StringComparison.Ordinal);
        Assert.Contains(AiRedaction.RedactionMarker, json, StringComparison.Ordinal);
    }

    [Fact]
    public void Serialization_RedactsASecretTypedIntoAnIdentifierField()
    {
        // Identifiers are included in the sanitizer because opaque does not mean harmless: an operator
        // pasting a connection string into a tenant field is a plausible accident, and the cost of
        // covering it is a string scan.
        var record = Record(tenantId: Secret());

        var json = AiAuditSerialization.Serialize(record);

        Assert.DoesNotContain(Secret(), json, StringComparison.Ordinal);
        Assert.Contains(AiRedaction.RedactionMarker, json, StringComparison.Ordinal);
    }

    [Fact]
    public void Serialization_RedactsASecretInAContextReference()
    {
        var record = Record() with
        {
            ContextReferences =
            [
                new AiContextReference
                {
                    ContextItemId = Secret(),
                    Classification = DataClassification.Public,

                    // Withheld, because the referenced item is classified Secret. A hash of a secret
                    // in a durable record would extend the secret's reach rather than bound it.
                    ContentHash = null,
                },
            ],
        };

        var json = AiAuditSerialization.Serialize(record);

        Assert.DoesNotContain(Secret(), json, StringComparison.Ordinal);
    }

    [Fact]
    public void AnOrdinaryRecord_SerializesVerbatim_WhichIsWhatMakesTheRedactionEvidence()
    {
        // CONTROL for the three tests above: the same serializer, the same shape of record, ordinary
        // values. A serializer that redacted everything would pass every assertion above and produce
        // an audit trail with nothing in it.
        var record = Record(purpose: "Summarise the release notes for the platform team.");

        var json = AiAuditSerialization.Serialize(record);

        Assert.Contains("Summarise the release notes for the platform team.", json, StringComparison.Ordinal);
        Assert.DoesNotContain(AiRedaction.RedactionMarker, json, StringComparison.Ordinal);
    }

    [Fact]
    public void TheEmitter_SanitizesOnTheWayOut_EvenWhenTheContextItWasHandedWasNot()
    {
        // The emitter is the path every record in the estate takes. Handing it a context whose free
        // text carries a secret is the closest a test can come to an operator pasting one into a
        // request, and the record that lands in the sink must already be redacted.
        var sink = new InMemoryAiAuditSink();
        var emitter = new AiAuditEmitter(sink);

        var record = emitter.Emit(new AiAuditEmissionContext
        {
            ExecutionId = "exec-w7e-sanitize",
            RequestId = "req-w7e-sanitize",
            CorrelationId = "corr-w7e-sanitize",
            Requester = Requester(),
            Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
            Purpose = $"Operator note: {Secret()}",
            Classification = DataClassification.Public,
            Timestamp = DateTimeOffset.UtcNow,
            Status = AiExecutionStatus.Succeeded,
        });

        Assert.DoesNotContain(Secret(), record.Purpose, StringComparison.Ordinal);

        var stored = sink.Find("exec-w7e-sanitize");
        Assert.NotNull(stored);
        Assert.DoesNotContain(Secret(), stored!.Purpose, StringComparison.Ordinal);
    }

    // ---------------------------------------------------------------------------------------------
    // 3. The operational read surface.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheReadModel_AnswersOneExecutionWithoutReachingInternalState()
    {
        var path = GovernedPath.Compose(TwoRoutes(tokensIn: 200, tokensOut: 80));

        var outcome = Run(path);
        var view = path.Operations.Execution(outcome.AuditReference!);

        Assert.NotNull(view);

        // Request and execution status.
        Assert.Equal("req-w7d", view!.RequestId);
        Assert.Equal("corr-w7d", view.CorrelationId);
        Assert.Equal(AiExecutionStatus.Succeeded, view.Status);

        // Routing and provider/model selection. Both configured routes were eligible; the one the
        // ranker preferred is the one that served, and the other is the fallback the failover never
        // needed to reach.
        Assert.Equal(PrimaryProvider, view.ProviderId);
        Assert.Equal(PrimaryModel, view.ModelId);
        Assert.Equal(2, view.EligibleRoutes);
        Assert.Equal(0, view.RejectedRoutes);

        // Health as it was at the time, and the governance result.
        Assert.Equal(AiModelHealthState.Available, view.ModelHealth);
        Assert.True(view.GovernanceAllowed);

        // Tokens, cost basis and latency.
        Assert.Equal(200, view.TokensIn);
        Assert.Equal(80, view.TokensOut);
        Assert.Equal(280, view.TotalTokens);
        Assert.Equal(AiCostBasis.Unpriced, view.CostBasis);

        // Fallback, and the tier the decision was taken under.
        Assert.False(view.UsedFallback);
        Assert.Equal(AiProcessingTier.Standard, view.Tier);
    }

    [Fact]
    public void TheReadModel_MakesAFailureCategoryObservable()
    {
        // TASK 14's "failure categories are observable", asked of the read surface rather than of the
        // outcome object - because the read surface is what an operator actually has.
        var path = GovernedPath.Compose(
            TwoRoutes(failingModels: [PrimaryModel, AlternateModel], fallbackDepth: 1));

        var outcome = Run(path);

        Assert.False(Succeeded(outcome));

        var view = path.Operations.Execution(outcome.AuditReference!)!;

        Assert.NotNull(view.FailureCategory);
        Assert.NotEqual(AiExecutionStatus.Succeeded, view.Status);

        // It is filterable, which is what makes it a category rather than a note. The same query with
        // a category nothing failed with returns nothing - the control that keeps this from being a
        // query that returns whatever it is given.
        Assert.Single(path.Operations.Executions(
            new AiOperationsQuery { FailureCategoryIn = [view.FailureCategory!.Value] }));

        Assert.Empty(path.Operations.Executions(
            new AiOperationsQuery { FailureCategoryIn = [OtherThan(view.FailureCategory.Value)] }));
    }

    [Fact]
    public void TheReadModel_ExposesTheFailoverDecisionAndTheRoutesItConsidered()
    {
        var path = GovernedPath.Compose(TwoRoutes(failingModels: [PrimaryModel]));

        var outcome = Run(path);
        var view = path.Operations.Execution(outcome.AuditReference!)!;

        Assert.True(view.UsedFallback);
        Assert.Equal(AiFailoverReasonCode.AlternateSucceeded, view.FailoverReasonCode);
        Assert.Equal(2, view.FailoverAttempts.Count);
        Assert.Equal(AlternateProvider, view.ProviderId);
    }

    [Fact]
    public void TheReadModel_SummarizesAnExecutionThatFailedOver_AgainstTheRouteThatServedIt()
    {
        var path = GovernedPath.Compose(TwoRoutes(failingModels: [PrimaryModel], tokensIn: 30, tokensOut: 10));

        Run(path);

        var byModel = path.Operations.Summarize(new AiOperationsQuery(), AiUsageGroupBy.Model);

        // ONE execution, bucketed against the route that served it. The rollup counts executions
        // rather than provider calls, and both calls belong to the same execution - so the primary's
        // failed attempt appears as the fallback count rather than as a second execution, which would
        // double the estate's apparent traffic.
        Assert.Equal(1, byModel.Executions);

        var served = Assert.Single(byModel.Buckets);
        Assert.Equal(AlternateModel, served.Key);
        Assert.Equal(1, served.Succeeded);
        Assert.Equal(1, served.FallbackExecutions);

        // BOTH calls' tokens, because the unit here is the execution and the execution paid for both.
        // 30 in and 10 out on the failed attempt, and again on the one that served. A rollup that
        // reported only the successful call's tokens would under-report exactly the traffic failover
        // produces, which is the number an operator watching spend needs most.
        Assert.Equal(80, served.TotalTokens);

        // The failed attempt is not lost: it is on the execution view and on the failover record, and
        // the spend it incurred is in the ledger. What the rollup refuses to do is count one execution
        // twice.
        Assert.DoesNotContain(byModel.Buckets, bucket => bucket.Key == PrimaryModel);

        var byProvider = path.Operations.Summarize(new AiOperationsQuery(), AiUsageGroupBy.Provider);
        Assert.Equal(AlternateProvider, Assert.Single(byProvider.Buckets).Key);
    }

    [Fact]
    public void TheReadModel_CountsAFailureAgainstTheCategoryThatCausedIt()
    {
        // The other half: when nothing serves the request, the execution is bucketed by how it failed
        // and the category is a countable thing rather than a note in a message.
        var path = GovernedPath.Compose(
            TwoRoutes(failingModels: [PrimaryModel, AlternateModel], fallbackDepth: 1));

        var outcome = Run(path);
        var byCapability = path.Operations.Summarize(
            new AiOperationsQuery(),
            AiUsageGroupBy.Capability);

        var category = path.Operations.Execution(outcome.AuditReference!)!.FailureCategory!.Value;

        // One bucket, for the capability that was asked for, and the failure is counted under its own
        // category inside it. A bucket that recorded only "1 failed" would leave an operator unable to
        // tell a capacity problem from a policy one without reading every record.
        var bucket = Assert.Single(byCapability.Buckets);

        Assert.Equal(AiCapabilities.ChatComplete, bucket.Key);
        Assert.Equal(1, bucket.Failed);
        Assert.Equal(0, bucket.Succeeded);
        Assert.Equal(1, bucket.FailuresByCategory[category]);

        // The category is also a filterable dimension on its own, which is how an operator asks "what
        // has been failing with this category" rather than "what has this capability been doing".
        Assert.Single(path.Operations.Executions(
            new AiOperationsQuery { FailureCategoryIn = [category] }));
    }

    [Fact]
    public void TheReadModel_SeparatesTheGovernanceResultFromTheOperationalOne()
    {
        // A route refused before a provider was reached is a different fact from a route that was
        // reached and failed, and an operations surface that merged them would report an outage that
        // never happened.
        var path = GovernedPath.Compose(TwoRoutes(providerApproval: "Suspended"));

        var outcome = Run(path);
        var view = path.Operations.Execution(outcome.AuditReference!)!;

        Assert.False(view.GovernanceAllowed);
        Assert.Null(view.ProviderId);
        Assert.False(view.UsedFallback);
        Assert.NotEmpty(view.GovernanceRules);
    }

    // ---------------------------------------------------------------------------------------------
    // 4. Trace and audit: one authority each, and one reference between them.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheTracePointsAtTheEvidence_AndTheEvidenceDoesNotPointBack()
    {
        // TASK 10. The turn trace is the decision narrative; the audit record is the governance and
        // cost evidence. The reference runs one way, so there is exactly one authority for "what
        // governance decided and what it cost" and no second copy that could disagree.
        var path = GovernedPath.Compose(TwoRoutes());

        var outcome = Run(path);

        // The trace carries the reference.
        Assert.False(string.IsNullOrWhiteSpace(outcome.AuditReference));
        Assert.NotEmpty(outcome.Decisions);

        // The audit record's shape has no field pointing back at the trace.
        var names = typeof(AiAuditRecord)
            .GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Select(property => property.Name)
            .ToArray();

        Assert.DoesNotContain(names, name =>
            name.Contains("Trace", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void TwoDistinctRequests_ProduceTwoRecords_AndNeitherIsLost()
    {
        // The sink is keyed by execution, so two executions are two records. A sink that kept only the
        // most recent would look like working software until someone asked about last Tuesday.
        var path = GovernedPath.Compose(TwoRoutes());

        var first = Run(path, "req-w7e-first");
        var second = Run(path, "req-w7e-second");

        Assert.NotEqual(first.AuditReference, second.AuditReference);
        Assert.Equal(2, path.Audit.Count);

        Assert.NotNull(path.Audit.Find(first.AuditReference!));
        Assert.NotNull(path.Audit.Find(second.AuditReference!));
    }

    [Fact]
    public void ReusingARequestIdentifier_NoLongerReplacesItsAuditRecord()
    {
        // W7E CF-9, inverted by W7F TASK 2. This test previously asserted the opposite, and it was right
        // to at the time: the execution identifier WAS the caller's request identifier and the sink is
        // keyed by it, so a replay under one request identifier produced one record and the first
        // execution's evidence was overwritten. The assertion is inverted rather than deleted so that
        // the defect it recorded is still being checked — from the other side, where it would fail if
        // the identifier were ever recoupled.
        //
        // The two identifiers now answer different questions. The request identifier is the caller's and
        // is stable across a replay by design; the execution identity is the AI Head's and is minted once
        // per execution. A replay is therefore a second execution with its own record, and the first
        // remains resolvable.
        var path = GovernedPath.Compose(TwoRoutes());

        var first = Run(path, "req-w7e-replay");
        var second = Run(path, "req-w7e-replay");

        Assert.NotEqual(first.AuditReference, second.AuditReference);
        Assert.Equal(2, path.Audit.Count);

        var firstRecord = path.Audit.Find(first.AuditReference!);
        var secondRecord = path.Audit.Find(second.AuditReference!);

        Assert.NotNull(firstRecord);
        Assert.NotNull(secondRecord);

        // Both records carry the ONE request identifier the caller used. That pair of facts — the
        // caller's identity preserved, the estate's evidence not overwritten — is the whole correction.
        Assert.Equal("req-w7e-replay", firstRecord!.RequestId);
        Assert.Equal("req-w7e-replay", secondRecord!.RequestId);

        // NON-VACUITY: they are two executions rather than one record found twice, so the two lookups
        // above are two lookups and not the same object returned for both references.
        Assert.NotEqual(firstRecord.ExecutionId, secondRecord.ExecutionId);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    /// <summary>An audit record of the shape the emitter builds, for the sanitizer tests.</summary>
    private static AiAuditRecord Record(
        string purpose = "W7E audit fixture.",
        string? tenantId = null) => new()
        {
            ExecutionId = "exec-w7e-audit",
            RequestId = "req-w7e-audit",
            CorrelationId = "corr-w7e-audit",
            Requester = Requester() with { TenantId = tenantId },
            Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
            Purpose = purpose,
            Classification = DataClassification.Public,
            ProviderUsed = PrimaryProvider,
            ModelUsed = PrimaryModel,
            Usage = new AiTokenUsage { InputTokens = 10, OutputTokens = 5 },
            Timing = new AiTiming { Total = TimeSpan.FromMilliseconds(120) },
            PolicyDecision = AiPolicyDecision.AllowedByDefault,
            Status = AiExecutionStatus.Succeeded,
            Timestamp = DateTimeOffset.UtcNow,
        };

    /// <summary>A credential-shaped value, assembled at run time rather than written as a literal.</summary>
    /// <remarks>
    /// <b>The estate's own convention, and it is followed here for the estate's own reason.</b> A source
    /// file containing a complete credential prefix is a file every secret scanner flags on every
    /// commit, and one a future reader has to classify by hand. The fragments are joined at run time
    /// and behave identically — the redactor recognises the assembled value exactly as it would a
    /// literal. No real credential is used, read, copied or tested: this string is fabricated in the
    /// test process and exists nowhere else.
    /// </remarks>
    private static string Secret() => "s" + "k-" + new string('w', 24);

    /// <summary>A failure category other than the one given, for a negative query.</summary>
    private static AiFailureCategory OtherThan(AiFailureCategory category)
        => Enum.GetValues<AiFailureCategory>().First(candidate => candidate != category);
}
