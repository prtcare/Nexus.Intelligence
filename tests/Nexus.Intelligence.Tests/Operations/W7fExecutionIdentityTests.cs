using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Turns;
using Nexus.Intelligence.Tests.Turns;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Operations;

// W7F TASK 2 and TASK 12: execution identity, and what a replay, a refusal and a fallback each produce.
//
// WHY THIS FILE EXISTS. W7E recorded CF-9 — that a reused request identifier replaced its predecessor's
// audit record — and named W7F as the owner of the decision. The decision is that the caller's request
// identifier and the AI Head's execution identity are different facts with different owners, and the
// consequence is that the two stores keyed on the execution identity now accumulate where they used to
// overwrite.
//
// WHAT MAKES THESE TESTS WORTH RUNNING. Every one composes the real governed path — the real W7B
// engine, the real W7C router and registries, the real W7D stages, the real W7E ledger, audit sink and
// evidence store — over a deterministic identity source, so an assertion names the identity the estate
// wrote rather than observing that two GUIDs differed. The controls say what would have to be true of
// the CODE for an assertion to hold vacuously, and then show it is not.
public sealed class W7fExecutionIdentityTests
{
    // ---------------------------------------------------------------------------------------------
    // TASK 2: one execution, one identity — minted by the AI Head, not supplied by the caller.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void AGovernedExecution_CarriesAnIdentityOfItsOwn()
    {
        // Four writers, one fact. The outcome, the ledger entry, the execution evidence and the audit
        // record all name the same execution, which is what makes an execution resolvable from any of
        // the four directions rather than from the one the reader happened to hold.
        var path = GovernedPath.Compose(TwoRoutes(tokensIn: 40, tokensOut: 10));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome), "The fixture must reach a provider for this test to mean anything.");

        Assert.Equal("exec-0001", outcome.ExecutionId);

        // The audit reference IS the execution identity, because the audit record is keyed by it.
        Assert.Equal(outcome.ExecutionId, outcome.AuditReference);

        // ...and the ledger's entry for the provider call carries it, alongside its attempt ordinal.
        var entries = path.Ledger.Entries();

        var entry = Assert.Single(entries);

        Assert.Equal("exec-0001", entry.ExecutionId);
        Assert.Equal("exec-0001:1", entry.AttemptId);
        Assert.Equal("req-w7d", entry.RequestId);
    }

    [Fact]
    public void TheExecutionIdentity_IsNotTheCallersRequestIdentifier()
    {
        // TASK 2's actual instruction: "Do not use ExecutionId == RequestId as the persisted execution
        // identity." Asserted as an inequality against the identifier the caller supplied, so a build
        // that quietly reverted to writing the request identifier into the ledger fails here rather than
        // at the next audit review.
        var path = GovernedPath.Compose(TwoRoutes());

        var outcome = Run(path, "req-w7f-identity");
        var record = path.Audit.Find(outcome.AuditReference!)!;

        Assert.NotEqual("req-w7f-identity", outcome.ExecutionId);

        // The record keeps BOTH, and they differ. A reader resolving by request identifier finds every
        // execution that answered it; a reader resolving by execution identity finds exactly one.
        Assert.Equal("req-w7f-identity", record.RequestId);
        Assert.Equal(outcome.ExecutionId, record.ExecutionId);
        Assert.NotEqual(record.RequestId, record.ExecutionId);
    }

    [Fact]
    public void ARefusedExecution_StillCarriesAnIdentity()
    {
        // An unregistered instruction set is refused at the first stage, so this is the earliest exit
        // from the stage sequence and it returns before a route exists. It still has to be resolvable,
        // because a refusal is the record an auditor most wants. A path that minted the identity where
        // routing happens would leave this execution with no identity and no audit record at all.
        var path = GovernedPath.Compose(TwoRoutes());

        var outcome = Run(
            path,
            GovernedPath.Turn(path.Options, agentId: "developer", promptId: "prompt.not-registered"));

        Assert.False(outcome.Invoked);
        Assert.Equal("exec-0001", outcome.ExecutionId);
        Assert.Equal(outcome.ExecutionId, outcome.AuditReference);

        // NON-VACUITY: the refusal is a real refusal and not a turn that happened to succeed, so the
        // identity above belongs to an execution that reached nothing.
        Assert.NotNull(outcome.Failure);
        Assert.NotNull(path.Audit.Find(outcome.AuditReference!));
    }

    // ---------------------------------------------------------------------------------------------
    // TASK 12: replay and refusal, each producing its own execution.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void ReplayingARequestIdentifier_ProducesTwoExecutionsAndLosesNothing()
    {
        // TASK 12's "same RequestId replay" and "replay does not overwrite audit evidence", and the
        // correction of CF-9. The caller repeats itself; the estate spent twice; the record says so and
        // the first execution's evidence survives.
        var path = GovernedPath.Compose(TwoRoutes(tokensIn: 30, tokensOut: 10));

        var first = Run(path, "req-w7f-replay");
        var second = Run(path, "req-w7f-replay");

        Assert.Equal("exec-0001", first.ExecutionId);
        Assert.Equal("exec-0002", second.ExecutionId);

        // Two records, both resolvable, and the first was not replaced by the second.
        Assert.Equal(2, path.Audit.Count);

        var firstRecord = path.Audit.Find(first.AuditReference!);
        var secondRecord = path.Audit.Find(second.AuditReference!);

        Assert.NotNull(firstRecord);
        Assert.NotNull(secondRecord);

        // Both records carry the caller's ONE request identifier, and they are two executions. That pair
        // of facts — the caller's identity preserved, the estate's evidence not overwritten — is the
        // whole model.
        Assert.Equal("req-w7f-replay", firstRecord!.RequestId);
        Assert.Equal("req-w7f-replay", secondRecord!.RequestId);
        Assert.NotEqual(firstRecord.ExecutionId, secondRecord.ExecutionId);

        // The spend is counted twice, which is the honest consequence and the reason any of this matters.
        var entries = path.Ledger.Entries();

        Assert.Equal(2, entries.Count);
        Assert.Equal(["exec-0001:1", "exec-0002:1"], entries.Select(entry => entry.AttemptId).ToArray());
    }

    [Fact]
    public void ExecutionsThatReachedNoProvider_StillMintOneIdentityEach()
    {
        // CONTROL for the test above, from the refusal side. Two executions that reached nothing are
        // still two executions, because the identity is minted per call to ExecuteAsync rather than per
        // provider invocation. Without this, a build that minted inside InvokeAsync would satisfy every
        // assertion above and produce no identity at all for a refused turn.
        var path = GovernedPath.Compose(TwoRoutes(providerApproval: "Suspended"));

        var first = Run(path, "req-w7f-refused");
        var second = Run(path, "req-w7f-refused");

        Assert.False(first.Invoked);
        Assert.False(second.Invoked);

        Assert.Equal("exec-0001", first.ExecutionId);
        Assert.Equal("exec-0002", second.ExecutionId);
        Assert.Equal(2, path.Audit.Count);

        // ...and nothing was recorded as spend, because nothing was spent. An identity is not an
        // invocation, and the ledger must not read as though it were.
        Assert.Empty(path.Ledger.Entries());
    }

    [Fact]
    public void AFallback_KeepsOneExecutionIdentityAndGivesEachAttemptItsOwn()
    {
        // TASK 12's "distinct identity per execution attempt" and "fallback remains separately
        // attributable", resolved the way the estate needs them. A fallback is not a second execution:
        // the routing decision, the governance decision and the exposure decision the audit record
        // carries are per-REQUEST facts, and splitting them across two execution identities would make
        // it ambiguous which execution the routing evidence belonged to. The calls are separated by
        // their attempt identity instead, which is what makes a fallback's spend attributable to it.
        var path = GovernedPath.Compose(
            TwoRoutes(tokensIn: 25, tokensOut: 5, failingModels: [PrimaryModel]));

        var outcome = Run(path);

        Assert.True(Succeeded(outcome), "The alternate must have served the request.");

        // One execution identity for the whole thing...
        Assert.Equal("exec-0001", outcome.ExecutionId);

        // ...and two provider calls under it, each with its own attempt identity and its own model.
        var entries = path.Ledger.Entries();

        Assert.Equal(["exec-0001:1", "exec-0001:2"], entries.Select(entry => entry.AttemptId).ToArray());

        Assert.Equal(PrimaryModel, entries[0].ModelId);
        Assert.False(entries[0].IsFallback);

        Assert.Equal(AlternateModel, entries[1].ModelId);
        Assert.True(entries[1].IsFallback);

        // NON-VACUITY: the two attempts differ by something other than their position in a list, so the
        // sequence above could not have been produced by one entry counted twice.
        Assert.NotEqual(entries[0].AttemptId, entries[1].AttemptId);
        Assert.NotEqual(entries[0].ModelId, entries[1].ModelId);
    }

    [Fact]
    public void TheAttemptOrdinal_RestartsForEachExecution()
    {
        // The counter belongs to the execution and not to the path. A counter on the path would make an
        // attempt identity depend on how many turns the process had served, so an execution's own
        // records could not be reconstructed from the execution — and the numbers would drift between
        // two runs of the same test, which is the failure a deterministic source exists to prevent.
        var path = GovernedPath.Compose(TwoRoutes());

        var first = Run(path);
        var second = Run(path);

        Assert.Equal(["exec-0001:1"], path.Ledger.Entries()
            .Where(entry => entry.ExecutionId == first.ExecutionId)
            .Select(entry => entry.AttemptId)
            .ToArray());

        Assert.Equal(["exec-0002:1"], path.Ledger.Entries()
            .Where(entry => entry.ExecutionId == second.ExecutionId)
            .Select(entry => entry.AttemptId)
            .ToArray());
    }

    // ---------------------------------------------------------------------------------------------
    // The explicit idempotency behaviour, through the live pipeline.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async System.Threading.Tasks.Task AReplayTheTurnStoreSuppresses_MintsNoExecutionIdentity()
    {
        // TASK 2's "define explicit idempotency behaviour", asserted as the composition of the two
        // controls rather than as either one alone. Suppressing a duplicate request is the live
        // pipeline's job: it resolves the idempotency key against the trace store and returns the
        // recorded trace without executing anything. This asserts the other half — that a replay the
        // pipeline suppresses never reaches the governed path, so it mints no execution identity at all
        // rather than minting one and discarding it.
        var options = new LivePathOptions();
        var path = LiveTurnPath.Compose(options);

        var first = await path.ExecuteAsync(LiveTurnPath.Turn(options));
        var second = await path.ExecuteAsync(LiveTurnPath.Turn(options));

        Assert.Equal(TurnOutcomeKind.Reply, first.Outcome);

        // The same turn came back both times, because the second call was served from the trace store.
        Assert.Equal(first.TurnId, second.TurnId);

        // Exactly one execution ran, and therefore exactly one identity was minted.
        Assert.Equal(1, path.Governed.Model.Count);
        Assert.Equal(1, path.Governed.ExecutionIds.Issued);
        Assert.Single(path.Governed.Ledger.Entries());

        // CONTROL: the same turn under a different idempotency key is a different logical request, so it
        // executes and mints a second identity. Without this, the assertions above would also pass on a
        // pipeline that had stopped executing anything at all.
        var third = await path.ExecuteAsync(
            LiveTurnPath.Turn(options, idempotencyKey: "idem-w7f-second"));

        Assert.NotEqual(first.TurnId, third.TurnId);
        Assert.Equal(2, path.Governed.Model.Count);
        Assert.Equal(2, path.Governed.ExecutionIds.Issued);
    }

    // ---------------------------------------------------------------------------------------------
    // The shipped source, and the shape of the fix.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheShippedIdentitySource_ProducesDistinctIdentifiersOfAKnownShape()
    {
        // The production default, exercised for the two properties the estate relies on: distinctness
        // across calls, and a shape that cannot be confused with a caller's request identifier or with
        // a turn identifier — both of which are minted by different code for different purposes.
        var source = new GuidAiExecutionIdSource();

        var issued = Enumerable.Range(0, 64).Select(_ => source.Next()).ToArray();

        Assert.Equal(64, issued.Distinct(StringComparer.Ordinal).Count());

        Assert.All(issued, id =>
        {
            Assert.Equal(32, id.Length);
            Assert.All(id, character => Assert.True(
                char.IsAsciiDigit(character) || (character >= 'a' && character <= 'f'),
                $"'{id}' is not a lowercase hexadecimal GUID in the \"N\" format."));
        });
    }

    [Fact]
    public void TheGovernedTurnRequest_CannotNameAnExecutionIdentity()
    {
        // TASK 2's structural half, over the type the identity is minted for: there is no member in
        // which a caller could supply an execution identity. This is the same argument
        // AiCapabilityRequest makes about models — a caller that cannot express a thing cannot ask for
        // it — and it is why the identity source is a constructor dependency rather than a request field.
        var names = typeof(GovernedTurnRequest)
            .GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Select(property => property.Name)
            .ToArray();

        Assert.DoesNotContain(names, name =>
            name.Contains("ExecutionId", StringComparison.OrdinalIgnoreCase));

        // CONTROL: the caller's own identities ARE expressible, so the absence above is a statement
        // about one member rather than about the reflection having looked at the wrong type.
        Assert.Contains("RequestId", names);
        Assert.Contains("IdempotencyKey", names);
        Assert.Contains("CorrelationId", names);
    }

    [Fact]
    public void TheUsageLedger_RequiresAnAttemptIdentityOnEveryEntry()
    {
        // The contract's half of the attempt model. `required` rather than optional is the assertion: an
        // optional member would make "this entry belongs to an unnamed attempt" representable, and the
        // ledger has one writer, at one call site, that always knows which attempt it is recording.
        var required = typeof(AiUsageEntry).GetProperty(nameof(AiUsageEntry.AttemptId));

        Assert.NotNull(required);

        Assert.True(
            required!.GetCustomAttributes<RequiredMemberAttribute>().Any(),
            "AiUsageEntry.AttemptId must be required, so an unnamed attempt cannot be written.");

        // CONTROL: a genuinely optional member on the same type is not required, so the assertion above
        // is reading the member it names rather than reporting a property of every member.
        var optional = typeof(AiUsageEntry).GetProperty(nameof(AiUsageEntry.ProductId));

        Assert.NotNull(optional);
        Assert.False(optional!.GetCustomAttributes<RequiredMemberAttribute>().Any());
    }

    [Fact]
    public void TheExecutionIdentity_IsNotAValidatorOfAnything()
    {
        // The identity is an identifier and nothing else. Asserted because the two ways it could quietly
        // acquire authority are both additions rather than edits: a member that turned it into a token,
        // and a member that made it a governance input. Neither exists, and the request type is where a
        // governance input would have to appear.
        var members = typeof(GovernedTurnOutcome)
            .GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Select(property => property.Name)
            .ToArray();

        Assert.Contains("ExecutionId", members);

        // The outcome carries no credential-shaped member, and no member whose name promises that the
        // identifier proves something. A name-based check is weak on its own, which is why it is paired
        // with the request-type check above — together they say no caller can supply one and no reader
        // can be handed one that means more than "which execution".
        Assert.DoesNotContain(members, name =>
            name.Contains("Token", StringComparison.OrdinalIgnoreCase)
            || name.Contains("Secret", StringComparison.OrdinalIgnoreCase)
            || name.Contains("Credential", StringComparison.OrdinalIgnoreCase));
    }
}
