using System.Collections.Generic;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Turns;
using Xunit;

namespace Nexus.Intelligence.Tests.Turns;

// W7D TASK 10: the tool guards, each paired with a control that produces the opposite result.
//
// WHAT THIS SUITE IS FOR. Every claim the directive names is a claim that something NEVER happens:
// a disallowed tool never executes, a prohibited surface cannot invoke tools, a side-effecting tool
// requires explicit permission, a refusal precedes the call, an unknown tool refuses, an agent cannot
// widen a grant, a human-gated tool cannot run silently. A test that asserts only the refusal passes
// on a system that refuses everything, so every guard below is asserted in BOTH directions from the
// same fixture with ONE field changed.
//
// HOW "NEVER EXECUTED" IS MEASURED. The tool gateway and the model step are recording seams over the
// real path: each counts every invocation it receives and succeeds when called. "The tool never
// executed" is therefore a count of zero on a collaborator that would otherwise have run - not an
// inference from a missing trace line, which a path that never reached the tool at all would also
// produce.
//
// TWO CLAIMS ARE PROVEN AT THE ENGINE rather than through the turn path, and each says why in place.
public sealed class W7dToolSafetyTests
{
    // ---------------------------------------------------------------------------------------------
    // 1. A tool the MODEL asks for but the execution did not offer never executes.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AToolTheModelAsksForButWasNotOffered_IsNeverExecuted()
    {
        // The grant is the offer. The model is free to name anything, and a name outside the offered
        // set has no descriptor for the loop to resolve - there is no second source of tools.
        var asked = new GovernedPathOptions
        {
            Tools = [GovernedPath.Tool("tool.echo")],
            OfferedToolIds = ["tool.echo"],
            Replies = ["[tool:tool.dangerous]{\"q\":\"x\"}", "Done."],
        };

        var path = GovernedPath.Compose(asked);
        var outcome = await path.ExecuteAsync(GovernedPath.Turn(asked));

        Assert.True(outcome.Invoked, outcome.Decision.Reason);

        // The model was reached and it did ask. Nothing answered the ask.
        Assert.Equal(1, path.Model.Count);
        Assert.Equal(0, path.Gateway.Count);

        var loop = Assert.IsType<ToolLoopResult>(outcome.Tools);
        Assert.Contains(loop.Decisions, trace => trace.What == "Skipped tool call 'tool.dangerous'");

        // CONTROL: the identical fixture with the single difference being the identifier in the
        // reply - the model asks for the tool that WAS offered - and the gateway is reached. So the
        // zero above was the offer, not a loop that cannot call anything.
        var offered = asked with { Replies = ["[tool:tool.echo]{\"q\":\"x\"}", "Done."] };
        var control = GovernedPath.Compose(offered);
        var executed = await control.ExecuteAsync(GovernedPath.Turn(offered));

        Assert.True(executed.Invoked, executed.Decision.Reason);
        Assert.Equal(1, control.Gateway.Count);
        Assert.Equal("tool.echo", control.Gateway.Invocations[0].ToolId);
    }

    // ---------------------------------------------------------------------------------------------
    // 2. An UNCLASSIFIED tool refuses, and refuses before the provider.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AnUnclassifiedTool_RefusesTheTurnBeforeTheProviderIsReached()
    {
        // The identifier is offered by the caller and known to the Platform catalogue. What is missing
        // is the AI registry's classification of its effect, and that absence is the refusal: a tool
        // register's failure mode is a newly registered tool being permitted because nobody classified
        // it, so ignorance is treated as the worst case rather than the most permissive one.
        var unclassified = new GovernedPathOptions { OfferedToolIds = ["tool.unclassified"] };

        var path = GovernedPath.Compose(unclassified);
        var outcome = await path.ExecuteAsync(GovernedPath.Turn(unclassified));

        Assert.False(outcome.Invoked);
        Assert.Equal(AiGovernanceRules.ToolUnknown, outcome.Decision.RuleId);
        Assert.Equal(AiFailureCategory.ToolPermissionDenied, outcome.Failure!.Category);

        // The refusal precedes the provider. An execution refused for an unclassifiable tool never
        // spent a token finding out, and the model seam confirms it: not one call arrived.
        Assert.Equal(0, path.Model.Count);
        Assert.Equal(0, path.Gateway.Count);

        // CONTROL: register the same identifier - the only change - and the identical turn executes.
        var classified = unclassified with { Tools = [GovernedPath.Tool("tool.unclassified")] };
        var control = GovernedPath.Compose(classified);
        var executed = await control.ExecuteAsync(GovernedPath.Turn(classified));

        Assert.True(executed.Invoked, executed.Decision.Reason);
        Assert.Equal(1, control.Model.Count);
    }

    // ---------------------------------------------------------------------------------------------
    // 3. An AI-PROHIBITED capability cannot reach a tool at all.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AnAiProhibitedCapability_CannotReachATool_AndProducesNoToolLoopAtAll()
    {
        // Everything that would let a tool run is in place: the tool is registered, classified as a
        // read, approved, and offered; the agent is approved and capped high enough. The prohibition
        // is the only thing standing, and it is enough.
        var prohibited = new GovernedPathOptions
        {
            Tools = [GovernedPath.Tool("tool.echo")],
            Agents = [GovernedPath.Agent("developer")],
            OfferedToolIds = ["tool.echo"],
            Dependencies = [GovernedPath.Prohibited(AiCapabilities.ChatComplete)],
            Replies = ["[tool:tool.echo]{\"q\":\"x\"}", "Done."],
        };

        var path = GovernedPath.Compose(prohibited);
        var outcome = await path.ExecuteAsync(GovernedPath.Turn(prohibited, agentId: "developer"));

        Assert.False(outcome.Invoked);
        Assert.Equal(AiGovernanceRules.ProhibitedCapability, outcome.Decision.RuleId);
        Assert.Equal(0, path.Model.Count);
        Assert.Equal(0, path.Gateway.Count);

        // Structural, and the reason "cannot invoke tools" is more than a count here: a refused
        // execution produces NO tool loop. There is nothing to invoke with, rather than a loop that
        // was created and declined to call.
        Assert.Null(outcome.Tools);

        // CONTROL: withdraw the declaration - the only change - and the same tool, offered by the same
        // turn, executes.
        var permitted = prohibited with { Dependencies = [] };
        var control = GovernedPath.Compose(permitted);
        var executed = await control.ExecuteAsync(GovernedPath.Turn(permitted, agentId: "developer"));

        Assert.True(executed.Invoked, executed.Decision.Reason);
        Assert.Equal(1, control.Gateway.Count);
        Assert.Equal("tool.echo", control.Gateway.Invocations[0].ToolId);
    }

    // ---------------------------------------------------------------------------------------------
    // 4. A SIDE-EFFECTING tool is not invoked on a turn, whatever the caller states.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task ASideEffectingTool_IsNotInvokedOnATurn_EvenWithEveryCallerPermissionWidened()
    {
        // The caller widens everything it controls: it permits side effects, it declines to require a
        // human for them, and it removes the write-approval posture from its own constraints. The
        // agent is capped at the tool's own class so the agent ceiling is not the binding constraint.
        // The turn still does not write, because the governed path derives its profile with
        // RequireApprovalForWrites set and a turn does not grant that to itself.
        var writing = new GovernedPathOptions
        {
            Tools = [GovernedPath.Tool("tool.mutate", sideEffect: "Write")],
            Agents = [GovernedPath.Agent("developer", maxSideEffect: "Write")],
            OfferedToolIds = ["tool.mutate"],
        };

        var requester = GovernedPath.Requester(
            mayCauseSideEffects: true,
            requiresHumanApprovalForSideEffects: false);
        var constraints = new TurnConstraints { RequireApprovalForWrites = false };

        var path = GovernedPath.Compose(writing);
        var outcome = await path.ExecuteAsync(
            GovernedPath.Turn(writing, agentId: "developer", requester: requester, constraints: constraints));

        Assert.False(outcome.Invoked);
        Assert.Equal(AiGovernanceRules.ToolApprovalRequired, outcome.Decision.RuleId);
        Assert.True(outcome.Decision.RequiresHumanDecision);

        // A human decision is not a failure and it is not an execution. Nothing ran.
        Assert.Equal(0, path.Model.Count);
        Assert.Equal(0, path.Gateway.Count);

        // CONTROL: the same turn offering the same tool identifier registered as a READ - the single
        // changed field - executes. So the zero above was the side effect and not a path that cannot
        // call tools at all.
        var reading = writing with { Tools = [GovernedPath.Tool("tool.mutate", sideEffect: "Read")] };
        var control = GovernedPath.Compose(reading);
        var executed = await control.ExecuteAsync(
            GovernedPath.Turn(reading, agentId: "developer", requester: requester, constraints: constraints));

        Assert.True(executed.Invoked, executed.Decision.Reason);
        Assert.Equal(1, control.Model.Count);
    }

    // ---------------------------------------------------------------------------------------------
    // 5. A refusal PRECEDES both the provider call and the tool call.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AGovernanceRefusal_PrecedesTheProviderCall_WhichPrecedesTheToolCall()
    {
        var unapproved = new GovernedPathOptions
        {
            Tools = [GovernedPath.Tool("tool.echo")],
            Agents = [GovernedPath.Agent("developer", approval: "Unregistered")],
            OfferedToolIds = ["tool.echo"],
            Replies = ["[tool:tool.echo]{\"q\":\"x\"}", "Done."],
        };

        var path = GovernedPath.Compose(unapproved);
        var outcome = await path.ExecuteAsync(GovernedPath.Turn(unapproved, agentId: "developer"));

        Assert.False(outcome.Invoked);
        Assert.Equal(AiGovernanceRules.AgentNotApproved, outcome.Decision.RuleId);

        // Both counters, because the two orderings are different claims. The tool call must not
        // happen, and neither must the provider call that would have preceded it - a path that
        // refused after spending a token would have a refusal and a bill.
        Assert.Equal(0, path.Gateway.Count);
        Assert.Equal(0, path.Model.Count);
        Assert.Null(outcome.Tools);

        // CONTROL: approve the agent - the only change - and the ordering becomes observable rather
        // than merely asserted: the model is reached first, the tool only afterwards, and the
        // continuation is a second model round.
        var approved = unapproved with { Agents = [GovernedPath.Agent("developer")] };
        var control = GovernedPath.Compose(approved);
        var executed = await control.ExecuteAsync(GovernedPath.Turn(approved, agentId: "developer"));

        Assert.True(executed.Invoked, executed.Decision.Reason);
        Assert.Equal(1, control.Gateway.Count);
        Assert.Equal(2, control.Model.Count);
    }

    // ---------------------------------------------------------------------------------------------
    // 6. An AGENT cannot widen a tool grant past its own ceiling.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AnAgentCannotReachATool_WhoseEffectExceedsItsOwnCeiling()
    {
        // The turn offers a read tool and the tool is fully registered and approved. The agent's own
        // ceiling is None, so the grant cannot be honoured: the profile's ceiling is derived from the
        // tools being offered and is checked against the agent, so offering a tool the agent was not
        // cleared for refuses rather than widening the agent's authority to match the offer.
        var capped = new GovernedPathOptions
        {
            Tools = [GovernedPath.Tool("tool.echo")],
            Agents = [GovernedPath.Agent("developer", maxSideEffect: "None")],
            OfferedToolIds = ["tool.echo"],
        };

        var path = GovernedPath.Compose(capped);
        var outcome = await path.ExecuteAsync(GovernedPath.Turn(capped, agentId: "developer"));

        Assert.False(outcome.Invoked);
        Assert.Equal(AiGovernanceRules.ToolSideEffectExceeded, outcome.Decision.RuleId);
        Assert.Equal(0, path.Model.Count);
        Assert.Equal(0, path.Gateway.Count);

        // CONTROL: raise the agent's OWN ceiling by one class - the only change - and the same tool,
        // offered by the same turn, is reached. The ceiling was the binding constraint, and it is the
        // agent's, not the caller's.
        var cleared = capped with { Agents = [GovernedPath.Agent("developer", maxSideEffect: "Read")] };
        var control = GovernedPath.Compose(cleared);
        var executed = await control.ExecuteAsync(GovernedPath.Turn(cleared, agentId: "developer"));

        Assert.True(executed.Invoked, executed.Decision.Reason);
        Assert.Equal(1, control.Model.Count);
    }

    // ---------------------------------------------------------------------------------------------
    // 7. A HUMAN-GATED tool cannot execute silently.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AToolDeclaredHumanGated_IsNotInvoked_EvenWithEveryCallerPermissionWidened()
    {
        // The tool is declared permanently human-gated in the registry. The caller has widened
        // everything it controls and the agent is capped at the tool's own class, so no other gate is
        // in the way - and the turn still stops for a person.
        var gated = new GovernedPathOptions
        {
            Tools = [GovernedPath.Tool("tool.release", sideEffect: "Destructive", requiresHumanApproval: true)],
            Agents = [GovernedPath.Agent("developer", maxSideEffect: "Destructive")],
            OfferedToolIds = ["tool.release"],
        };

        var requester = GovernedPath.Requester(
            mayCauseSideEffects: true,
            requiresHumanApprovalForSideEffects: false);
        var constraints = new TurnConstraints { RequireApprovalForWrites = false };

        var path = GovernedPath.Compose(gated);
        var outcome = await path.ExecuteAsync(
            GovernedPath.Turn(gated, agentId: "developer", requester: requester, constraints: constraints));

        Assert.False(outcome.Invoked);
        Assert.Equal(AiGovernanceRules.ToolApprovalRequired, outcome.Decision.RuleId);
        Assert.True(outcome.Decision.RequiresHumanDecision);
        Assert.Equal(0, path.Gateway.Count);
        Assert.Equal(0, path.Model.Count);
    }

    [Fact]
    public void AToolDeclaredHumanGated_RefusesWhenNoOtherGateWould()
    {
        // Engine level, and the reason this half is not redundant with the one above: it isolates the
        // TOOL'S OWN declaration. The profile does not require approval for writes and the requester
        // does not require it either, so every other source of a human decision has been turned off.
        // The tool's flag alone is sufficient, which is what makes it a property of the tool rather
        // than of the caller's caution.
        var profile = new ToolPermissionProfile
        {
            AllowedToolIds = ["tool.release"],
            MaxSideEffect = ToolSideEffectClass.Destructive,
            RequireApprovalForWrites = false,
            MaxToolCalls = 5,
        };

        var gated = ToolEvaluator([Rule("tool.release", ToolSideEffectClass.Destructive, requiresHumanApproval: true)]);
        var decision = gated.Evaluate(
            ToolRequest("tool.release", profile), AiPlatformGovernanceAttestation.NotApplicable);

        Assert.True(decision.RequiresHumanDecision);
        Assert.Equal(AiGovernanceRules.ToolApprovalRequired, decision.RuleId);

        // CONTROL: the same rule with the flag withdrawn - the only change - and the identical request
        // is allowed. So the decision above was the declaration and not the profile or the requester.
        var ungated = ToolEvaluator([Rule("tool.release", ToolSideEffectClass.Destructive)]);
        var allowed = ungated.Evaluate(
            ToolRequest("tool.release", profile), AiPlatformGovernanceAttestation.NotApplicable);

        Assert.True(allowed.IsAllowed, allowed.Reason);
    }

    [Fact]
    public void EveryBaselineProhibitedSurface_IsRefused_WhateverToolIsOffered()
    {
        // The surface half of Task 10, and this is where it has to be tested. A surface is refused at
        // the engine's FIRST stage, from the deterministic baseline rather than from a register
        // lookup, so it does not depend on anyone having written a declaration. Every baseline surface
        // is refused for a request that is otherwise permitted and carrying a permitted tool.
        //
        // WHY NOT THROUGH THE TURN PATH: a turn envelope names no protected surface, so the governed
        // execution has nothing to set TouchesSurface from and never sets it. That is a real limit and
        // it is recorded here rather than papered over - see the W7D report. What is provable is that
        // the gate itself cannot be escaped by any tool configuration, which is what this asserts.
        var profile = new ToolPermissionProfile
        {
            AllowedToolIds = ["tool.echo"],
            MaxSideEffect = ToolSideEffectClass.Read,
            RequireApprovalForWrites = false,
            MaxToolCalls = 5,
        };

        var evaluator = ToolEvaluator([Rule("tool.echo", ToolSideEffectClass.Read)]);
        var request = ToolRequest("tool.echo", profile);

        // CONTROL: the request permitted, so the refusals below are the surface and not a fixture
        // that cannot allow anything.
        Assert.True(
            evaluator.Evaluate(request, AiPlatformGovernanceAttestation.NotApplicable).IsAllowed);

        foreach (var surface in AiProhibitionBaseline.RequiredSurfaces)
        {
            var decision = evaluator.Evaluate(
                request with { TouchesSurface = surface },
                AiPlatformGovernanceAttestation.NotApplicable);

            Assert.True(decision.IsBlocked, $"Surface '{surface}' was not refused.");
            Assert.Equal(AiGovernanceRules.ProhibitedSurface, decision.RuleId);
            Assert.Contains(surface.ToString(), decision.RulesApplied);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    /// <summary>An engine over a policy whose tool table is the only populated dimension.</summary>
    private static DeterministicAiGovernanceEvaluator ToolEvaluator(IReadOnlyList<AiGovernanceToolRule> tools) =>
        new(new AiGovernancePolicy
        {
            Dependencies = AiDependencyRegistry.Empty,
            Capabilities = AiCapabilityRegister.Bootstrap(),
            Exposure = DataExposurePolicy.Default(),
            Register = EmptyAiGovernanceRegister.Instance,
            Budgets = [],

            // The models here are unstated, so nothing is priced and the cost dimension is inert.
            RequireBudgetRuleForPricedExecution = false,
            Tools = tools,
            Escalations = [],
        });

    private static AiGovernanceToolRule Rule(
        string toolId,
        ToolSideEffectClass sideEffect,
        bool requiresHumanApproval = false) => new()
        {
            RuleId = $"tool.{toolId}",
            ToolId = toolId,
            SideEffect = sideEffect,
            RequiresHumanApproval = requiresHumanApproval,
            Rationale = "W7D test fixture.",
        };

    /// <summary>
    /// A request whose only populated governance dimension is the tool table. Every other gate is
    /// stated in its permitting form so a refusal names the tool gate rather than a neighbour.
    /// </summary>
    private static AiGovernanceEvaluationRequest ToolRequest(string toolId, ToolPermissionProfile profile) => new()
    {
        RequestId = "req-w7d-tools",
        Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
        Requester = GovernedPath.Requester(
            mayCauseSideEffects: true,
            requiresHumanApprovalForSideEffects: false),
        Classification = DataClassification.Public,
        Execution = AiExecutionPolicy.Default,
        Destination = AiDestinationClass.Local,
        Tools = profile,
        RequestedToolIds = [toolId],
        CorrelationId = "corr-w7d-tools",
    };
}
