using System.Collections.Generic;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Turns;
using Xunit;

namespace Nexus.Intelligence.Tests.Turns;

// W7D TASK 11: the data-exposure guards, each paired with a control that produces the opposite result.
//
// WHAT THESE FIXTURES PROVE AND WHAT THEY DO NOT. Each is a negative fixture: it asserts that something
// did not reach the provider seam, and it is paired with a control built from the same fixture with one
// field changed that does reach it. A negative fixture without its control passes on a path that reaches
// nothing at all, which is why every guard below has one.
//
// Two of the directive's five claims are narrower in this estate than the directive's wording, and both
// are said where they arise rather than smoothed over: an item cannot be scoped to a tenant, and a
// caller's own declared classification is an assertion rather than a fact.
public sealed class W7dContextSafetyTests
{
    // A distinctive body, so a match is a match and not a coincidence of common words.
    private const string SecretBody = "the vault combination is brass-lantern-nine";

    // ---------------------------------------------------------------------------------------------
    // 1. A classification the exposure policy forbids blocks the provider invocation entirely.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AForbiddenClassification_BlocksTheProviderInvocation()
    {
        // Secret is the classification whose disclosure is itself the incident, and the default policy
        // admits it to no destination at all. The refusal therefore happens in the request-scope
        // governance pass, before any route is looked up.
        var options = new GovernedPathOptions();

        var path = GovernedPath.Compose(options);
        var blocked = await path.ExecuteAsync(GovernedPath.Turn(options, DataClassification.Secret));

        Assert.False(blocked.Invoked);
        Assert.Equal(AiGovernanceRules.ExposureBlocked, blocked.Decision.RuleId);
        Assert.Equal(AiFailureCategory.DataExposureBlocked, blocked.Failure!.Category);

        // NEGATIVE: not one call reached the seam, and no route was even selected to call.
        Assert.Equal(0, path.Model.Count);
        Assert.Null(blocked.Routing!.Selected);

        // CONTROL: the identical turn classified Public - the only change - executes. So the zero above
        // was the classification and not a fixture that cannot invoke anything.
        var control = GovernedPath.Compose(options);
        var executed = await control.ExecuteAsync(GovernedPath.Turn(options, DataClassification.Public));

        Assert.True(executed.Invoked, executed.Decision.Reason);
        Assert.Equal(1, control.Model.Count);
    }

    // ---------------------------------------------------------------------------------------------
    // 2. Secret content is not emitted to the provider by default.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task ASecretContextItem_IsNotSentToTheProvider()
    {
        // The request itself is Internal and may go. The item is Secret and may not, so the builder
        // excludes it whole. The item is excluded rather than truncated, and the model is told nothing
        // about it beyond that the answer was built without something.
        var options = new GovernedPathOptions();
        var context = GovernedPath.Context(GovernedPath.Item("doc.vault", SecretBody, DataClassification.Secret));

        var path = GovernedPath.Compose(options);
        var outcome = await path.ExecuteAsync(GovernedPath.Turn(options, DataClassification.Internal, context));

        Assert.True(outcome.Invoked, outcome.Decision.Reason);
        Assert.Equal(1, path.Model.Count);

        // NEGATIVE: the provider was reached, and what it was sent does not contain the secret. The
        // assertion is against the text actually handed to the seam, not against a filtered copy made
        // for the test.
        Assert.DoesNotContain(SecretBody, path.Model.SentText, StringComparison.Ordinal);

        // ...and the exclusion is reported rather than silent, and the item is absent from the context
        // the outcome describes as having been used.
        Assert.Contains(outcome.Decisions, trace => trace.What == "Withheld 1 context item(s) from the execution");
        Assert.Empty(outcome.Context);

        // CONTROL: the same item classified Internal - the only change - and it IS sent. So the absence
        // above was the classification and not a prompt that omits context altogether.
        var control = GovernedPath.Compose(options);
        var admitted = await control.ExecuteAsync(GovernedPath.Turn(
            options,
            DataClassification.Internal,
            GovernedPath.Context(GovernedPath.Item("doc.vault", SecretBody, DataClassification.Internal))));

        Assert.True(admitted.Invoked, admitted.Decision.Reason);
        Assert.Contains(SecretBody, control.Model.SentText, StringComparison.Ordinal);
    }

    // ---------------------------------------------------------------------------------------------
    // 3. Context cannot declare, or satisfy, the scope governance checks.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AContextItemNamingAnotherTenant_DoesNotDeclareAScope_AndTheTurnIsRefused()
    {
        // THE CLAIM, STATED HONESTLY. ContextItem carries no tenant and no workspace field, so this
        // estate cannot check one item's origin against another's, and a test claiming per-item
        // cross-tenant isolation would be claiming a control that does not exist. What does exist is
        // that the scope in play is the requester's, is stated by the envelope, and cannot be derived
        // from anything the caller attaches. That is what this asserts, and the item below is the
        // attempt to supply one by the only means available - a tag.
        var options = new GovernedPathOptions();
        var claiming = GovernedPath.Context(GovernedPath.Item(
            "doc.other-tenant",
            "material belonging to somebody else",
            DataClassification.Confidential,
            tags: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["tenant"] = "tenant-other",
                ["workspace"] = "workspace-other",
            }));

        var path = GovernedPath.Compose(options);
        var outcome = await path.ExecuteAsync(GovernedPath.Turn(
            options,
            DataClassification.Internal,
            claiming,
            requester: GovernedPath.Requester(dataScopes: [])));

        Assert.False(outcome.Invoked);
        Assert.Equal(AiGovernanceRules.ContextScopeUndeclared, outcome.Decision.RuleId);
        Assert.Equal(0, path.Model.Count);

        // NEGATIVE: the tags named a tenant and a workspace and neither was accepted as the requester's
        // scope. The gate fired because the requester declared none - so an attached scope claim is not
        // a scope declaration, whatever it calls itself.
        Assert.Contains(
            "the requester declared no data scope",
            outcome.Decision.Reason,
            StringComparison.Ordinal);

        // CONTROL: the same request with the scope declared on the requester - the only change - and the
        // turn proceeds. So the refusal above was the missing declaration and not the tags, which are
        // still present and still inert.
        var control = GovernedPath.Compose(options);
        var executed = await control.ExecuteAsync(GovernedPath.Turn(
            options,
            DataClassification.Internal,
            claiming,
            requester: GovernedPath.Requester(dataScopes: ["tenant:acme"])));

        Assert.True(executed.Invoked, executed.Decision.Reason);
        Assert.Equal(1, control.Model.Count);
    }

    // ---------------------------------------------------------------------------------------------
    // 4. A caller cannot lower a context item's classification by declaring a lower one.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task ACallerCannotOverrideAClassificationDownward()
    {
        // The request declares Public and the item declares Secret. The request proceeds - Public is a
        // classification the policy admits, and the caller's declaration about the request as a whole is
        // theirs to make. The item's own declaration is what governs the item, and it is excluded.
        //
        // WHAT THIS DOES NOT CLAIM: that the request's declared classification has been verified. It has
        // not, and it cannot be - a caller asserting Public about content it is actually sending as
        // Internal is asserting something no component in this path can check. The guarantee is narrower
        // and it is the one that matters here: a lower request classification does not lift an item's
        // own, so declaring Public does not make a Secret attachment sendable.
        var options = new GovernedPathOptions();

        var path = GovernedPath.Compose(options);
        var outcome = await path.ExecuteAsync(GovernedPath.Turn(
            options,
            DataClassification.Public,
            GovernedPath.Context(GovernedPath.Item("doc.vault", SecretBody, DataClassification.Secret))));

        Assert.True(outcome.Invoked, outcome.Decision.Reason);
        Assert.DoesNotContain(SecretBody, path.Model.SentText, StringComparison.Ordinal);
        Assert.Contains(outcome.Decisions, trace => trace.What == "Withheld 1 context item(s) from the execution");

        // CONTROL: the same turn and the same request classification with the item classified Public -
        // the only change - and it is sent. The request's Public declaration admitted it on its own
        // merits, which is exactly the point: the item's declaration decided, not the request's.
        var control = GovernedPath.Compose(options);
        var admitted = await control.ExecuteAsync(GovernedPath.Turn(
            options,
            DataClassification.Public,
            GovernedPath.Context(GovernedPath.Item("doc.vault", SecretBody, DataClassification.Public))));

        Assert.True(admitted.Invoked, admitted.Decision.Reason);
        Assert.Contains(SecretBody, control.Model.SentText, StringComparison.Ordinal);
    }

    // ---------------------------------------------------------------------------------------------
    // 5. Redaction runs before the governed provider invocation, not after it.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task Redaction_HappensBeforeTheGovernedProviderInvocation()
    {
        // Confidential requires redaction, so the body is redacted between the builder and the ranking,
        // and the text that reaches the provider seam is the redacted text. The assertion is against the
        // text the seam was handed: redaction that happened after assembly would leave the raw token in
        // the messages the seam received.
        const string Token = "sk-live-9f2b7c1d4e6a8b0c";
        var body = $"The deployment key is {Token} and it must not leave the estate.";

        var options = new GovernedPathOptions();
        var context = GovernedPath.Context(GovernedPath.Item("doc.key", body, DataClassification.Confidential));

        var path = GovernedPath.Compose(options);
        var outcome = await path.ExecuteAsync(GovernedPath.Turn(
            options,
            DataClassification.Confidential,
            context));

        Assert.True(outcome.Invoked, outcome.Decision.Reason);
        Assert.Equal(1, path.Model.Count);

        // NEGATIVE: the provider was reached, and what it was handed carries the marker and not the
        // token. Both halves are asserted, because a marker with the token still beside it would satisfy
        // only the first.
        Assert.Contains(AiRedaction.RedactionMarker, path.Model.SentText, StringComparison.Ordinal);
        Assert.DoesNotContain(Token, path.Model.SentText, StringComparison.Ordinal);

        // CONTROL: the same body under a request classification that requires no redaction - the only
        // change - and the token IS sent. So the marker above came from the redaction stage and not from
        // a fixture whose text never contained a token to begin with.
        var control = GovernedPath.Compose(options);
        var raw = await control.ExecuteAsync(GovernedPath.Turn(
            options,
            DataClassification.Internal,
            context));

        Assert.True(raw.Invoked, raw.Decision.Reason);
        Assert.Contains(Token, control.Model.SentText, StringComparison.Ordinal);
        Assert.DoesNotContain(AiRedaction.RedactionMarker, control.Model.SentText, StringComparison.Ordinal);
    }
}
