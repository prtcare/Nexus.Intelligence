using System.Text.Json;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Planning;
using Nexus.Intelligence.Core.Turns;
using Nexus.Platform.Contracts.Models;
using Xunit;

namespace Nexus.Intelligence.Tests.Planning;

/// <summary>
/// W10.7A pre-merge remediation — <b>a governed planning refusal must not be an empty successful
/// plan.</b>
///
/// <para>
/// <b>This file is the harness the endpoint never had.</b> <c>PlansEndpoints</c>, <c>Planner</c>,
/// <c>ResultsEndpoints</c>, <c>TurnRequestValidation</c> and <c>InMemoryResultReportStore</c> had zero
/// test references anywhere in the suite (gap G-3), so nothing composed the planning path before this.
/// </para>
/// <para>
/// <b>Why the assertions are on the serialized form.</b> <c>PlansEndpoints</c> is
/// <c>Results.Ok(plan)</c> verbatim, so the serialized plan IS the response body. Asserting on it is a
/// statement about what a caller receives, not about an in-process value — and it is what makes "a
/// refusal cannot be READ as an empty plan" a real claim.
/// </para>
/// </remarks>
public sealed class PlanRefusalTests
{
    private static readonly JsonSerializerOptions Wire = new(JsonSerializerDefaults.Web);

    private sealed class StubExecution(GovernedTurnOutcome outcome) : IGovernedTurnExecution
    {
        public int Calls { get; private set; }

        public Task<GovernedTurnOutcome> ExecuteAsync(GovernedTurnRequest request, CancellationToken ct = default)
        {
            Calls++;
            return Task.FromResult(outcome);
        }
    }

    private sealed class NullTraceStore : ITurnTraceStore
    {
        public Task AddAsync(TurnTrace trace, CancellationToken ct = default) => Task.CompletedTask;

        public Task<TurnTrace?> GetAsync(string turnId, CancellationToken ct = default)
            => Task.FromResult<TurnTrace?>(null);

        public Task<TurnTrace?> FindByIdempotencyKeyAsync(
            string tenantId, string productId, string idempotencyKey, CancellationToken ct = default)
            => Task.FromResult<TurnTrace?>(null);
    }

    private static GovernedTurnOutcome Available() => Outcome(
        invoked: true, decision: AiGovernanceDecision.Allow(),
        content: """{"steps":[{"id":"s1","title":"first"},{"id":"s2","title":"second"}]}""");

    private static GovernedTurnOutcome Empty() => Outcome(
        invoked: true, decision: AiGovernanceDecision.Allow(), content: string.Empty);

    private static GovernedTurnOutcome Refused() => Outcome(
        invoked: false,
        decision: AiGovernanceDecision.Block(
            "governance.classification_exceeded",
            "The request's classification exceeds what this capability may be given.",
            AiFailureCategory.PolicyBlocked),
        content: null);

    private static GovernedTurnOutcome Outcome(bool invoked, AiGovernanceDecision decision, string? content) => new()
    {
        ExecutionId = "exec-plan-1",
        Decision = decision,
        Invoked = invoked,
        Result = invoked && content is not null
            ? new ModelStepResult(
                new ModelInvocationResult
                {
                    Success = true,
                    Message = new ModelMessage { Role = ModelRole.Assistant, Content = content },
                    Usage = new ModelUsage(10, 5, 0m),
                    ModelUsed = "openai:gpt-4.1",
                },
                new DecisionTrace("invoked", "seam", []))
            : null,
    };

    private static async Task<(PlanPayload Plan, int Calls)> PlanAsync(GovernedTurnOutcome outcome)
    {
        var execution = new StubExecution(outcome);
        var planner = new Planner(execution, new NullTraceStore(), TimeProvider.System);

        var plan = await planner.CreatePlanAsync(new IntelligenceTurnRequest
        {
            TenantId = "tenant-1",
            ProductId = "product-1",
            IdempotencyKey = "idem-1",
            Scope = new ScopeRef("workspace", "ws-1", []),
            Actor = new ActorRef("user-1", [], []),
            Input = new TurnInput(TurnInputKind.UserMessage, "plan this", []),
        });

        return (plan, execution.Calls);
    }

    private static string WireShape(PlanPayload plan) => JsonSerializer.Serialize(plan, Wire);

    // ---------------------------------------------------------------------------------------------
    // TASK 8 — the three outcomes, each asserted for what it IS and what it is NOT.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task A_permitted_plan_carries_its_steps_and_no_refusal()
    {
        var (plan, _) = await PlanAsync(Available());

        Assert.Equal(PlanOutcomeKind.Available, plan.Outcome);
        Assert.Equal(2, plan.Steps.Count);
        Assert.Null(plan.Refusal);
    }

    [Fact]
    public async Task A_permitted_but_empty_plan_is_Empty_and_is_not_a_refusal()
    {
        var (plan, _) = await PlanAsync(Empty());

        Assert.Equal(PlanOutcomeKind.Empty, plan.Outcome);
        Assert.Empty(plan.Steps);

        // NOT a refusal. The estate permitted this request and the model returned nothing usable — a
        // successful non-answer, which is a different fact from a policy decision.
        Assert.Null(plan.Refusal);
    }

    [Fact]
    public async Task A_governed_refusal_carries_a_refusal_and_no_plan()
    {
        var (plan, _) = await PlanAsync(Refused());

        Assert.Equal(PlanOutcomeKind.Refused, plan.Outcome);
        Assert.NotNull(plan.Refusal);
        Assert.Equal("governance.classification_exceeded", plan.Refusal!.RuleId);

        // TASK 7 — no plan was produced, so there are no steps and no plan identity is manufactured.
        Assert.Empty(plan.Steps);
    }

    /// <summary>
    /// <b>`PLANS_REFUSAL_COLLAPSE_REPRODUCED` → the guard is load-bearing.</b>
    /// </summary>
    /// <remarks>
    /// <para>
    /// This test asserted the DEFECT before the fix: that a refusal and a legitimately empty plan
    /// serialized to the SAME BYTES. It passed against the old implementation, and it is inverted here —
    /// which is the point. A regression that cannot fail against the broken implementation proves
    /// nothing, and "the defect is gone" is only a claim if something would contradict it.
    /// </para>
    /// <para>
    /// TASK 10's sensitivity control restores the old collapse and confirms this test fails again:
    /// <c>PLANS_REFUSAL_GUARD_LOAD_BEARING</c>.
    /// </para>
    /// </remarks>
    [Fact]
    public async Task An_empty_plan_and_a_refusal_do_not_serialize_alike()
    {
        var (empty, _) = await PlanAsync(Empty());
        var (refused, _) = await PlanAsync(Refused());

        Assert.NotEqual(WireShape(empty), WireShape(refused));
    }

    [Fact]
    public async Task A_refusal_cannot_be_read_as_a_valid_empty_plan()
    {
        // What a caller actually does: parse the body and ask what it got. A refusal whose outcome were
        // absent or defaulted would land on Available — or on Empty, given the empty step list — either
        // of which is the estate answering a question it refused.
        var (refused, _) = await PlanAsync(Refused());

        using var document = JsonDocument.Parse(WireShape(refused));
        var root = document.RootElement;

        // Asserted as the NUMBER the contract actually puts on the wire. The estate serializes enums
        // numerically, and a test that asserted a string would be claiming a representation nobody chose.
        Assert.Equal((int)PlanOutcomeKind.Refused, root.GetProperty("outcome").GetInt32());

        // ...and the refusal metadata is ON THE WIRE, not only in the in-process object.
        Assert.Equal(JsonValueKind.Object, root.GetProperty("refusal").ValueKind);
    }

    [Fact]
    public async Task A_successful_empty_plan_cannot_be_mistaken_for_a_refusal()
    {
        // The other direction — and why both are asserted. A fix that marked every step-less result as
        // refused would satisfy the test above and be just as wrong.
        var (empty, _) = await PlanAsync(Empty());

        using var document = JsonDocument.Parse(WireShape(empty));
        var root = document.RootElement;

        Assert.Equal((int)PlanOutcomeKind.Empty, root.GetProperty("outcome").GetInt32());
        Assert.Equal(JsonValueKind.Null, root.GetProperty("refusal").ValueKind);
    }

    [Fact]
    public async Task A_refusal_carries_a_stable_reason_a_caller_can_branch_on()
    {
        // TASK 6. Stable means it is an identifier, not prose, and does not vary between two identical
        // refusals.
        var (first, _) = await PlanAsync(Refused());
        var (second, _) = await PlanAsync(Refused());

        Assert.Equal(first.Refusal!.ReasonCode, second.Refusal!.ReasonCode);
        Assert.Equal(first.Refusal.Message, second.Refusal.Message);
        Assert.False(string.IsNullOrWhiteSpace(first.Refusal.ReasonCode));
    }

    [Fact]
    public async Task A_permitted_plan_is_unchanged_by_the_refusal_contract()
    {
        // TASK 8 case 8, and the compatibility half. An existing caller reads `steps`; that member keeps
        // its position, its type and its meaning. The outcome is ADDED, so nothing that worked before
        // stops working.
        var (plan, _) = await PlanAsync(Available());

        using var document = JsonDocument.Parse(WireShape(plan));
        var root = document.RootElement;

        Assert.Equal(JsonValueKind.Array, root.GetProperty("steps").ValueKind);
        Assert.Equal(2, root.GetProperty("steps").GetArrayLength());
        Assert.Equal((int)PlanOutcomeKind.Available, root.GetProperty("outcome").GetInt32());
        Assert.Equal(JsonValueKind.Null, root.GetProperty("refusal").ValueKind);
    }

    [Fact]
    public async Task The_refusal_is_reached_without_a_provider_being_invoked()
    {
        // TASK 8 case 7. The governed path runs in order to DECIDE — that is the decision — and a refusal
        // is taken before any model is reached. The seam is entered once and invokes nothing.
        var (plan, calls) = await PlanAsync(Refused());

        Assert.Equal(PlanOutcomeKind.Refused, plan.Outcome);
        Assert.Equal(1, calls);
        Assert.Empty(plan.Steps);
    }
}
