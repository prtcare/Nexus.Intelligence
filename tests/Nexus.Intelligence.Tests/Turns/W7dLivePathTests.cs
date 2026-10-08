using System.Collections.Generic;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Turns;
using Xunit;

namespace Nexus.Intelligence.Tests.Turns;

// W7D TASK 12: the live TurnPipeline, end to end.
//
// WHAT THESE TESTS ARE FOR. Every other suite in W7D exercises the governed path directly. These exercise
// it the way a Product does - through TurnPipeline, with a Product's envelope - because the directive's
// claim is about the LIVE path: "the live TurnPipeline must stop selecting/executing AI outside the
// W7B/W7C governance + registry path". A governed path that the live pipeline does not actually use would
// pass every other test in this lane and still be the wrong answer.
//
// The provider and tool seams are deterministic fakes, so nothing here needs a credential, a network or
// an activated provider. No test in this file reads, resolves or references a secret value.
public sealed class W7dLivePathTests
{
    private const string RoutedModel = "prov-w7d:model-a";

    // ---------------------------------------------------------------------------------------------
    // 1. The positive path: envelope → governed context → registry route → governed provider seam.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task ASemanticRequest_ReachesTheProviderThroughTheRegistryRoute_WithGovernedContext()
    {
        const string Internal = "the retry policy is documented in the runbook";
        const string Secret = "the vault combination is brass-lantern-nine";

        var options = new LivePathOptions();
        var context = GovernedPath.Context(
            GovernedPath.Item("doc.runbook", Internal, DataClassification.Internal),
            GovernedPath.Item("doc.vault", Secret, DataClassification.Secret));

        var path = LiveTurnPath.Compose(options);
        var response = await path.ExecuteAsync(LiveTurnPath.Turn(
            options,
            input: "review this",
            kind: TurnInputKind.Task,
            context: context));

        // A Product asked a question and got an answer, in the shape it has always got one.
        Assert.Equal(TurnOutcomeKind.Reply, response.Outcome);
        Assert.Empty(response.Errors);

        // ...and the answer came from a provider seam that was reached exactly once, on the route the
        // registry selected. The caller named no model; the envelope has no field in which to name one.
        Assert.Equal(1, path.Model.Count);
        Assert.Equal(RoutedModel, path.Model.Invocations[0].ModelId);
        Assert.Equal(RoutedModel, response.Usage.ModelUsed);

        // ...and the context was governed before it was sent: the Internal item reached the provider and
        // the Secret item did not, on a request the exposure policy admitted.
        Assert.Contains(Internal, path.Model.SentText, StringComparison.Ordinal);
        Assert.DoesNotContain(Secret, path.Model.SentText, StringComparison.Ordinal);

        // ...and the routing decision is in the turn trace, so an operator reading the record sees the
        // route rather than inferring it from the reply.
        Assert.True(
            path.TraceContains(response, $"Routed the turn to '{RoutedModel}'"),
            "The turn trace does not record the route the registry selected.");

        // The turn is persisted. A turn that was served and not recorded is the audit hole the trace
        // store exists to prevent.
        var persisted = await path.Traces.FindByIdempotencyKeyAsync("tenant-acme", "nexus-developer", "idem-w7d-live");
        Assert.NotNull(persisted);
        Assert.Equal(response.TurnId, persisted!.TurnId);
    }

    // ---------------------------------------------------------------------------------------------
    // 2. A blocked request results in zero provider calls.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AProhibitedCapability_RefusesTheLiveTurn_WithZeroProviderCalls()
    {
        // The estate has declared that this capability has no AI path at all. The refusal is the
        // request-scope pass, so it does not depend on which model is available.
        var options = new LivePathOptions
        {
            Governed = new GovernedPathOptions
            {
                Dependencies = [GovernedPath.Prohibited(AiCapabilities.ChatComplete)],
            },
        };

        var path = LiveTurnPath.Compose(options);
        var response = await path.ExecuteAsync(LiveTurnPath.Turn(options));

        Assert.Equal(TurnOutcomeKind.Refusal, response.Outcome);
        Assert.Equal(AiGovernanceRules.ProhibitedCapability, response.Errors[0].Code);

        // NEGATIVE: zero. Not one provider call and not one tool call - the refusal precedes both, so
        // the Product's refused turn was also a turn that cost nothing.
        Assert.Equal(0, path.Model.Count);
        Assert.Equal(0, path.Gateway.Count);

        // CONTROL: withdraw the declaration - the only change - and the identical request is served.
        var permitted = new LivePathOptions { Governed = new GovernedPathOptions { Dependencies = [] } };
        var control = LiveTurnPath.Compose(permitted);
        var served = await control.ExecuteAsync(LiveTurnPath.Turn(permitted));

        Assert.Equal(TurnOutcomeKind.Reply, served.Outcome);
        Assert.Equal(1, control.Model.Count);
    }

    [Fact]
    public async Task AModelNotApprovedInTheRegistry_RefusesTheLiveTurn_WithZeroProviderCalls()
    {
        // The model exists, serves the capability and is healthy; its approval says it may not be used.
        // Nothing in the pipeline knows that — the refusal is governance reading the registry, which is
        // what makes this an end-to-end proof rather than a property of a fixture.
        var options = new LivePathOptions
        {
            Governed = new GovernedPathOptions { ModelApproval = "Suspended" },
        };

        var path = LiveTurnPath.Compose(options);
        var response = await path.ExecuteAsync(LiveTurnPath.Turn(options));

        Assert.Equal(TurnOutcomeKind.Refusal, response.Outcome);
        Assert.Equal(AiGovernanceRules.ModelNotApproved, response.Errors[0].Code);
        Assert.Equal(0, path.Model.Count);
        Assert.Equal(0, path.Gateway.Count);

        // CONTROL: approve the model - the only change - and the same turn is served on it.
        var approved = new LivePathOptions { Governed = new GovernedPathOptions { ModelApproval = "Approved" } };
        var control = LiveTurnPath.Compose(approved);
        var served = await control.ExecuteAsync(LiveTurnPath.Turn(approved));

        Assert.Equal(TurnOutcomeKind.Reply, served.Outcome);
        Assert.Equal(1, control.Model.Count);
    }

    // ---------------------------------------------------------------------------------------------
    // 3. A caller cannot steer the route, and a role assignment is not a route either.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task ACallersModelHint_IsRecordedAndNotHonoured()
    {
        const string Hint = "openai:gpt-4.1";

        var options = new LivePathOptions();

        var path = LiveTurnPath.Compose(options);
        var response = await path.ExecuteAsync(LiveTurnPath.Turn(
            options,
            input: "review this",
            kind: TurnInputKind.Task,
            modelHint: Hint));

        Assert.Equal(TurnOutcomeKind.Reply, response.Outcome);

        // The hint was seen, and the trace says so rather than dropping it silently.
        Assert.True(
            path.TraceContains(response, $"Ignored the caller's model hint '{Hint}'"),
            "The turn trace does not record the caller's ignored model hint.");

        // NEGATIVE: the provider was reached, and what it was reached as is the registry's route - not
        // the model the caller named, which is not even a model the governed registry declares.
        Assert.Equal(1, path.Model.Count);
        Assert.Equal(RoutedModel, path.Model.Invocations[0].ModelId);
        Assert.NotEqual(Hint, path.Model.Invocations[0].ModelId);
        Assert.Equal(RoutedModel, response.Usage.ModelUsed);
    }

    [Fact]
    public async Task TheRolesAssignedModel_IsReportedAgainstTheRoute_AndDoesNotRoute()
    {
        // W7D TASK 9 on the live path. An operator assigned the default role to a model; that assignment
        // is not a route and cannot become one, because there is no preference channel in the routing
        // contract to carry it. What the assignment does get is an answer: the pipeline reports the
        // route it disagreed with, in the same trace as the route itself.
        const string Assigned = "openai:gpt-4.1";

        var options = new LivePathOptions { RoleModelId = Assigned };

        var path = LiveTurnPath.Compose(options);
        var response = await path.ExecuteAsync(LiveTurnPath.Turn(options, input: "review this", kind: TurnInputKind.Task));

        Assert.Equal(TurnOutcomeKind.Reply, response.Outcome);

        // The role was resolved and recorded. A role that silently stopped mattering would leave an
        // operator's configuration asserting something the estate no longer honours, with nothing saying
        // so - this is the trace line that says so.
        Assert.True(
            path.TraceContains(response, $"The role's assigned model '{Assigned}' differs from the routed model"),
            "The turn trace does not report the divergence between the role's expectation and the route.");

        // NEGATIVE: the assignment did not route. The provider was reached as the registry's model, and
        // the assignment's model is not a route the governed registry even declares.
        Assert.Equal(1, path.Model.Count);
        Assert.Equal(RoutedModel, path.Model.Invocations[0].ModelId);
        Assert.NotEqual(Assigned, path.Model.Invocations[0].ModelId);

        // CONTROL: the same fixture with no assignment - the only change - serves the same route. So the
        // route above was the registry's answer both times, and the assignment changed nothing about it.
        var unassigned = new LivePathOptions();
        var control = LiveTurnPath.Compose(unassigned);
        var served = await control.ExecuteAsync(
            LiveTurnPath.Turn(unassigned, input: "review this", kind: TurnInputKind.Task));

        Assert.Equal(RoutedModel, served.Usage.ModelUsed);
        Assert.Equal(1, control.Model.Count);
    }

    // ---------------------------------------------------------------------------------------------
    // 4. The pipeline's tool narrowing reaches the AI registry, not just the Platform catalogue.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AToolThePlatformOffers_ButTheAiRegistryDoesNotClassify_RefusesTheLiveTurn()
    {
        // The Platform catalogue offers the tool and the caller's gate permits it - both narrowings that
        // happen before the governed path. The AI registry has never classified it, and that absence is
        // the refusal.
        //
        // The agent is capped at Destructive deliberately. An unclassified tool is inferred to be the
        // most severe class before the tool stage is reached, so an agent capped lower would refuse this
        // turn one stage earlier as ToolSideEffectExceeded - also correct, and a different rule. Capping
        // the agent at the worst class is what lets the tool registry's own refusal be the one observed.
        var options = new LivePathOptions
        {
            CatalogueToolIds = ["tool.unclassified"],
            Governed = new GovernedPathOptions
            {
                Agents = [GovernedPath.Agent("developer", maxSideEffect: "Destructive", promptId: AiPrompts.ConversationTurn)],
            },
        };

        var path = LiveTurnPath.Compose(options);
        var response = await path.ExecuteAsync(LiveTurnPath.Turn(
            options,
            input: "review this",
            kind: TurnInputKind.Task,
            allowedTools: ["tool.unclassified"]));

        Assert.Equal(TurnOutcomeKind.Refusal, response.Outcome);
        Assert.Equal(AiGovernanceRules.ToolUnknown, response.Errors[0].Code);
        Assert.Equal(0, path.Model.Count);
        Assert.Equal(0, path.Gateway.Count);

        // CONTROL: declare the same identifier in the AI registry - the only change - and the same
        // request is served. So the refusal above was the missing classification, not the offer.
        var declared = options with
        {
            Governed = options.Governed with { Tools = [GovernedPath.Tool("tool.unclassified")] },
        };

        var control = LiveTurnPath.Compose(declared);
        var served = await control.ExecuteAsync(LiveTurnPath.Turn(
            declared,
            input: "review this",
            kind: TurnInputKind.Task,
            allowedTools: ["tool.unclassified"]));

        Assert.Equal(TurnOutcomeKind.Reply, served.Outcome);
        Assert.Equal(1, control.Model.Count);
    }
}
