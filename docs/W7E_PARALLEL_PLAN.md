# W7E — Parallel Plan

**Lane:** W7E — AI Operations: cost, usage, health, reliability, failover & observability
**Branch:** `w7e/ai-operations`
**Worktree:** `D:/Nexus/AI/Intelligence.work/w7e-ai-operations`
**BaseSHA (new):** `b3514706bcc96f06cbc1f43fcd6cdb904f8bf2b6` (accepted W7D)
**BaseSHA (old):** N/A — no pre-existing W7E worktree or branch was found, so this is a clean
creation from the accepted W7D commit rather than a rebase. Nothing was recreated and no history
was rewritten.
**Rollback point:** `b351470` (identical to BaseSHA; it is the first W7E commit's parent)

Parent commit note: the W7E directive cites the accepted W7D commit as
`b3514706cc96f06cbc1f43fcd6cdb904f8bf2b6`. That string does not resolve — it is missing a
character. The real commit is `b3514706bcc96f06cbc1f43fcd6cdb904f8bf2b6` (`...4706bcc96...`),
verified to resolve in both the main repository and the W7D worktree. The worktree was created
from the real SHA. The discrepancy is recorded here rather than silently corrected.

---

## 1. The three proposed sub-lanes

The directive proposes:

- **A** — usage + cost ledger
- **B** — health + reliability snapshot
- **C** — observability + audit emitter

and asks whether they are collision-safe, to be developed in parallel only if their
**contracts**, **files** and **composition roots** do not collide.

## 2. Verdict

**A, B and C are NOT collision-safe as stated.** They collide in three independent ways, and one
of the three collisions is structural rather than incidental. The directive's own condition —
"they may be developed in parallel only if their contracts/files/composition roots do not
collide" — is therefore not met, and the correct action is to run them serially with one
amendment described in §5.

This is a finding about the *plan*, not a limitation of this session's executor count. It would
hold with three executors.

## 3. Collision analysis

### 3.1 Contract collision — `Nexus.Intelligence.Contracts`

The standing V3 rule is:

> No two lanes may add a type to `Nexus.Intelligence.Contracts` in the same integration window.

Collision surface C1–C7 makes that rule explicit for lane-vs-lane work, and it is the rule that
has kept W7B, W7C and W7D from producing competing vocabularies for the same concepts.

A, B and C are sub-lanes of *one* lane, so they share one integration window. Each of them adds
types to `Nexus.Intelligence.Contracts`:

| Lane | Types it must add to Contracts |
|---|---|
| A | usage entry, usage query, usage report, usage groupings; cost basis, cost entry, cost reconciliation; price quote, pricing status, pricing lookup state, price catalogue port |
| B | health observation, health probe port, health snapshot, snapshot store port; reliability attempt, reliability evidence, reliability policy, reliability history port |
| C | audit sink port, audit emitter; operations read model, operations event, operations query/summary |

Eleven-plus types across three sub-lanes into one assembly in one window. Under the standing rule
this is a collision regardless of which files they land in, because the rule is about the
assembly's vocabulary and not about file paths. The rule exists precisely because parallel
authors of the same vocabulary produce two names for one concept — `AiCostBasis` and
`AiUsageCostBasis`, `AiHealthState` and `AiModelHealthState` — and the duplicate is only
discovered at integration, when both are already referenced.

**Severity: blocking.** File partitioning does not fix it. A "contracts freeze" step does.

### 3.2 File collision — the composition root

Every sub-lane must be registered for the estate to use it, and there is exactly one registration
point: `src/Nexus.Intelligence.Api/DependencyInjection/IntelligenceServiceCollectionExtensions.cs`.

This is not a file that can be partitioned by directory convention, because the registrations are
order-dependent in two places that matter:

- `AiGovernancePolicy` is composed with `Register` and `Tools` resolved from the container, so the
  order in which `IAiGovernanceRegister` and `IAiToolRegistry` are registered determines what the
  policy widens to.
- `IAiCapabilityRouter` and `IGovernedTurnExecution` are built from already-registered ports, and
  both of them gain W7E dependencies (see §3.4).

Three lanes editing one 235-line method is the classic merge conflict whose resolution silently
drops a registration — and a dropped registration is not a compile error here, it is a
`Unable to resolve service` at first request or, worse, a fallback to a default that does not
refuse.

**Severity: blocking.** Mitigated by serialising, not by patching.

### 3.3 Produce/consume collision — C is downstream of A and B

The directive places C alongside A and B. C is not alongside them.

An observability read surface that reports, in the directive's own list — *tokens, cost, latency,
health, failure category* — must read A's usage/cost ledger and B's health snapshot. It cannot be
authored against contracts that do not exist yet without inventing them, which is collision §3.1
arriving by a second route.

So C splits:

- **C1 — audit emitter.** Emits `AiAuditRecord` from the governed execution path. Depends on the
  execution path only. Genuinely independent of A and B.
- **C2 — operations read model.** Projects A's ledger and B's snapshot into an operator surface.
  **Serial after A and B**, not parallel with them.

The directive says this about failover and is right to: *"Failover integration is SERIAL after A/B
because it consumes their outputs."* C2 has exactly the same shape and was not called out.

**Severity: blocking for C as stated.** Fixed by the split.

### 3.4 Dependency collision — the router and the execution path

Both A and B must be *consumed* to be operational, and both are consumed at the same two seams
that C1 also needs:

| Seam | A consumes | B consumes | C1 consumes |
|---|---|---|---|
| `GovernedCapabilityRouter` | budget/cost stage | reliability gate + health snapshot | — |
| `GovernedTurnExecution` | usage/cost recording | failover health re-check | audit emission |

Unless all three integration edits land together, the seams are edited three times. The directive
already forbids the alternative — *"Do not create another router or another provider invocation
path"* — so the router and the execution path are single points of edit by construction.

**Severity: serialising, not blocking.** This is inherent and acceptable; it is the reason the
integration is its own stage below.

### 3.5 Non-collision: the implementation directories

`src/Nexus.Intelligence.Core/Operations/` does not exist and is not referenced by any file today.
`tests/Nexus.Intelligence.Tests/Operations/` likewise. Within the implementation tree, A, B and C
are cleanly partitionable by file, and this part of the directive's proposal is sound.

**Severity: none.** This is the one place the three-lane split genuinely holds.

## 4. Serial dependency graph

```
   [0] contracts freeze  (one author, one window)
            |
     +------+------+
     |      |      |
   [A]    [B]   [C1]
     |      |      |
     +--+---+      |
        |          |
      [I] integration seams (router, execution path, composition root)
        |          |
        +----+-----+
             |
       [F] failover
             |
           [C2] operations read model
             |
        [V] verification
```

## 5. What is theoretically parallel-safe

Recorded as the directive requires, for a future window with more than one executor:

1. **The implementation halves of A, B and C1** — `Core/Operations/*` files and their test files —
   are parallel-safe **once lane 0 has frozen the contracts**. That is the whole amendment: the
   contracts freeze is serialised, and everything after it is not.
2. **C1's audit emitter is parallel-safe with A and B** without any amendment, because it touches
   neither the ledger nor the health snapshot. It is the only one of the three original lanes that
   survives as truly independent.
3. **A and B's test files** are parallel-safe unconditionally; they are new files in a new
   directory.
4. **Not parallel-safe under any partitioning:** the contracts assembly (§3.1), the composition
   root (§3.2), the two integration seams (§3.4), failover, and C2.

## 6. This session's execution

This session has one executor, so per the directive it executes sequentially:

**[0] → [A] → [B] → [C1] → [I] → [F] → [C2] → [V]**, committed in stages so each rollback point
is meaningful rather than one commit at the end.

## 7. Reserved ChangeScope

Reserving the following paths. No file outside this list is modified by W7E; a change outside it
is a scope breach and must be reverted rather than explained.

**New — contracts**
- `src/Nexus.Intelligence.Contracts/Operations/**`

**New — implementation**
- `src/Nexus.Intelligence.Core/Operations/**`

**New — tests**
- `tests/Nexus.Intelligence.Tests/Operations/**`
- `tests/Nexus.Intelligence.Architecture.Tests/W7e*.cs`

**Modified — the seams and the composition root**
- `src/Nexus.Intelligence.Api/DependencyInjection/IntelligenceServiceCollectionExtensions.cs`
- `src/Nexus.Intelligence.Api/Program.cs`
- `src/Nexus.Intelligence.Api/appsettings.json`
- `src/Nexus.Intelligence.Core/Routing/GovernedCapabilityRouter.cs`
- `src/Nexus.Intelligence.Core/Turns/GovernedTurnExecution.cs`
- `src/Nexus.Intelligence.Core/Turns/TurnPipeline.cs`
- `src/Nexus.Intelligence.Contracts/Routing/AiRoutingVocabulary.cs` (append-only: new rejection reasons)
- `src/Nexus.Intelligence.Contracts/Routing/AiRoutingOutcome.cs` (additive: operational evidence)
- `src/Nexus.Intelligence.Contracts/Registry/AiModelRegistration.cs` (additive: processing tiers)
- `src/Nexus.Intelligence.Contracts/Governance/AiGovernancePolicy.cs` (additive: operational budget scopes vary)
- `src/Nexus.Intelligence.Core/Registry/AiRegistryConfiguration.cs` (additive: tiers, operations section)

**Modified — test harnesses extended for the new router dependency**
- `tests/Nexus.Intelligence.Tests/Routing/GovernedCapabilityRouterTests.cs`
- `tests/Nexus.Intelligence.Tests/Turns/GovernedPath.cs`
- `tests/Nexus.Intelligence.Tests/Turns/LiveTurnPath.cs`

**New — documents**
- `docs/W7E_PARALLEL_PLAN.md` (this file)
- `docs/W7E_CARRY_FORWARD.md`

## 8. Standing constraints carried into this lane

- **Append-only on accepted vocabulary.** `AiRoutingRejectionReason` gains members at the end with
  explicit numbering. Existing members keep their values: a renumbered enum member silently
  changes the meaning of every persisted value that referenced it.
- **No second router, no second provider invocation path.** Failover re-enters
  `GovernedProviderInvocation` with a re-evaluated governance request; it never calls `IModelStep`
  directly.
- **No inline network health probe inside a routing decision.** Routing reads a snapshot. The
  probe runs out of band. This is asserted by test, not by convention.
- **`REQUIRES_HUMAN_SECRET_ROTATION` remains in force.** The historical provider credential is not
  read, tested, printed, copied or used by this lane or its tests. No W7E default, probe, fixture
  or configuration entry references it, and no test requires it.
- **`NEXUS_OPENAI_API_KEY` remains the approved default secret reference** and is not replaced with
  a vendor-conventional name.
- **No `Nexus.Platform.Providers.OpenAI` under Platform.** W7E does not touch the provider project
  tree; the only provider-side code it reads is `OpenAIModelGateway`'s existing meter call.
- **Atlas is not coupled in W7E.** The operations read surface is an AI Head port; no consumer
  adapter is written here.
