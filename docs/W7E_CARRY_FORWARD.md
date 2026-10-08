# W7E — Carry Forward

Items W7E deliberately did **not** fix, with the reason and the recommended later owner. Per the
W7E directive TASK 12: *"Do NOT silently broaden W7E into a large W7D rewrite. Carry these forward
explicitly unless a minimal operational integration requires them... Do not weaken current
enforcement."*

Nothing here is a defect W7E introduced. Every item is a pre-existing limitation that W7E
observed, verified still present, and left exactly as it found it.

---

## CF-1 — `GovernedTurnExecution.ProfileFor` hardcodes `RequireApprovalForWrites = true`

**Where:** `src/Nexus.Intelligence.Core/Turns/GovernedTurnExecution.cs`, `ProfileFor` (private,
~line 653–675).

**What it is:** the tool permission profile handed to the governance engine for every governed turn
is built with `RequireApprovalForWrites = true` as a literal. The consequence is that no
side-effecting tool can be invoked by a governed turn at all — a write tool either is refused or
raises a human-decision requirement, and there is no configuration under which a governed turn
performs a write.

**Why W7E did not fix it:** the value is a governance posture, not an operational one. Making it
configurable means deciding *who* may set it, *what* an unset value means, and whether a caller may
influence it — and the caller-facing types have no field for it by construction. A wrong answer
here turns a fail-closed posture into a fail-open one, which is the highest-consequence change
available in this estate. It is not a minimal operational integration for W7E, so it is carried.

**Why it must not be quietly relaxed:** the current value is the reason a governed turn cannot
perform a write. Any lane that changes it changes what the AI Head can *do*, not merely what it can
report.

**Recommended later owner:** **W7G / Tool Governance**, or whichever lane first needs a governed
turn to perform a side-effecting action. That lane must carry the decision as a governance act with
a record — a configuration field, a default that refuses, and a test proving the default refuses.

**Enforcement status:** unchanged. W7E adds no code path that can reach a tool invocation outside
`ToolLoop`, and does not alter `ProfileFor`.

---

## CF-2 — `AiAgentRegistration.AllowedToolIds` is declarative and unenforced

**Where:** `src/Nexus.Intelligence.Contracts/Registry/AiAgentRegistration.cs` (the member), and the
governance evaluator's agent stage, which reads only `MaxSideEffect`.

**What it is:** an agent registration may declare the tool identifiers it is allowed to use. Nothing
reads that list when deciding whether a tool call may proceed. The only enforced agent-level bound
on tools is `MaxSideEffect`. Effective tool enforcement today runs through the existing tool
governance path: the tool registry's `AiGovernanceToolRule` projection, the caller's
`ToolPermissionProfile`, and the side-effect ceiling.

**Consequence, stated plainly:** an agent declaring `AllowedToolIds: []` is not thereby forbidden
from invoking a tool. A tool invocation is bounded by the *tool's* classification and the
*caller's* profile, not by the agent's declaration. An operator reading an agent registration and
concluding that its tool list is enforced would be wrong.

**Why W7E did not fix it:** W7E is an operations lane. Enforcing `AllowedToolIds` changes which
tool calls succeed, which is a W7D-domain governance behaviour change with its own test surface
across the tool loop, the agent selector and the evaluator. The directive's own TASK 12 names this
as a carry-forward item and instructs that current enforcement not be weakened; adding enforcement
would be broadening W7E into a W7D rewrite.

**Recommended later owner:** **W7G / Tool Governance**, in the same lane as CF-1 — the two items
are the same question asked about two subjects (what may an agent do, and what may a turn do) and
splitting them across lanes would produce two answers.

**Enforcement status:** unchanged, and **not weakened**. W7E's operational gates add refusals
(reliability, budget, processing tier); they remove none. A tool call that was refused before W7E
is still refused after it, by the same rule.

---

## CF-3 — no per-item tenant/workspace scoping on context

**Where:** `ContextItem` carries no tenant or workspace member.

**What it is:** cross-tenant leakage *within* a single request is not detectable, because the
context items supplied by a caller do not state which tenant they were drawn from. The provable
claim is narrower: the scope governance checks is derived from the requester identity and the
envelope, and cannot be declared or satisfied by supplied context.

**Why it is carried:** it is a W7D context-model limitation, not an operations one, and W7E's
operations read model attributes usage by the *requester's* tenant/workspace — which is the
identity that exists. W7E does not invent a per-item scope that the model cannot support, because
an invented scope field that nothing populates would read as a control.

**Recommended later owner:** **W7D follow-up / Context Provenance**.

**Enforcement status:** unchanged. W7E reports the requester-scoped attribution it can actually
prove, and does not claim item-level scoping anywhere.

---

## CF-4 — `AiGovernanceEvaluationRequest.TouchesSurface` is unreachable from a turn

**Where:** `src/Nexus.Intelligence.Contracts/Governance/AiGovernanceEvaluationRequest.cs` (the
member); no W7D or W7E code path populates it.

**What it is:** the prohibition register's surface-form prohibitions cannot fire from a turn.
Only the capability-form prohibition is end-to-end provable. A request that sits on a prohibited
surface and does not declare it is a defect in the caller, and no caller-facing field can declare
one.

**Why it is carried:** populating it requires deciding what a caller may say about the surfaces it
touches, which is a caller-contract change and a governance-surface widening, not operations work.

**Recommended later owner:** **W7B follow-up / Prohibition Register**.

**Enforcement status:** unchanged.

---

## CF-5 — AI_ROLES is reconciled by divergence report, not by pin

**Where:** `TurnPipeline.RecordRoleOutcome`, `AiRoleResolver`.

**What it is:** the role's model pin was deliberately removed rather than preserved, because
`AiRoutingContext` forbids a model-preference channel — a caller that can express a model
preference is a caller selecting its own provider. The role's effect survives as a recorded
agreement/divergence check on the selected route: the pipeline records whether the route the
registry chose matches what the role assignment would have chosen, and reports when they diverge.

**Why it is carried:** this is a deliberate behavioural departure recorded by W7D, not a gap. W7E
extends it only by making the divergence observable on the operations read surface — a divergence
count per role — which is reporting, not a change of selection behaviour.

**Recommended later owner:** none. It is intended behaviour and is recorded here so it is not
rediscovered as a defect.

**Enforcement status:** unchanged.

---

## CF-6 — `IUsageMeter` is a Platform contract-plane type and cannot be extended here

**Where:** `Nexus.Platform.Contracts.Models` (pinned package
`Nexus.Platform.Contracts` `0.1.0-dev.20260912172543`), consumed as a binary.

**What it is:** `IUsageMeter` has exactly one method (`RecordAsync`) and `UsageRecord` carries
`Identity`, `ModelId`, `Usage` and `RecordedAt` — **no `ProviderId`, no `CapabilityId`, no
`ExecutionId`**. That is why provider attribution was unjoinable before W7E (directive TASK 11).

`tests/Nexus.Intelligence.Architecture.Tests/ModelDomainOwnershipTests.cs` asserts that
`IUsageMeter` and `UsageRecord` live in the Platform contract plane assembly, so an AI-owned copy
is not merely discouraged — it fails a test.

**What W7E did about it:** W7E does **not** modify the Platform package. It introduces an AI-owned
operational usage ledger (`IAiUsageLedger`) whose entry carries the full attribution, written once
per governed invocation from the routing outcome — where `ExecutionId`, `CapabilityId`,
`ProviderId` and `ModelId` are all known. The Platform meter remains the provider-level seam and
is left registered and untouched.

**Recommended later owner:** **Platform contract plane**, if a future lane needs provider
attribution *below* the AI Head — that is, inside the gateway, where the AI Head's routing identity
is not available. W7E's answer does not require it.

**Enforcement status:** unchanged. No AI-owned copy of a Platform contract type is declared.

---

## CF-7 — the historical provider credential remains `REQUIRES_HUMAN_SECRET_ROTATION`

**Where:** environment / operator custody, not the repository.

**What it is:** a historical provider credential still requires human rotation or revocation.

**What W7E did about it:** nothing, deliberately. W7E does not read it, test it, print it, copy it
or use it. No W7E default, probe, fixture, configuration entry or test references it. Every W7E
deterministic test passes without it — the health probes are injected fakes, the price catalogue
reads registry metadata, and the governed path terminates at a fake `IModelStep`.

**Recommended later owner:** **Human Owner**, for rotation. Not a software lane.

**Enforcement status:** the constraint remains active and is not discharged by this lane.

---

## CF-8 — `AiRoutingRejectionReason.ModelNotRegistered` is unreachable

**Where:** `src/Nexus.Intelligence.Contracts/Routing/AiRoutingVocabulary.cs`.

**What it is:** the enum member exists and no code path produces it. A model identifier inside a
registration always resolves its model, and the missing-provider case uses
`ProviderNotRegistered`.

**Why it is carried:** removing an enum member is a breaking change to a persisted vocabulary for
no behavioural gain, and renumbering it would change the meaning of stored values — the exact
defect the append-only rule in the parallel plan exists to prevent. W7E leaves it and records it so
the unreachable member is a known fact rather than a discovery.

**Recommended later owner:** none required. Recorded for accuracy of the vocabulary's coverage.

**Enforcement status:** not applicable.

---

## CF-9 — a reused request identifier replaces its audit record

**Where:** `GovernedTurnExecution.ExecutionId` is the caller's `RequestId`; `InMemoryAiAuditSink`
keys on `ExecutionId` and replaces.

**What it is:** two governed executions that carry the same request identifier do not produce two
audit records. The second replaces the first. The same is true of the execution evidence store,
which is keyed the same way. This was found by a W7E test that ran the same composed path twice
without naming distinct request identifiers and observed a single record rather than two — it is
recorded here because it is a property a consumer must design around, not because a test was
adjusted to accommodate it. The test that found it now exists in both forms: one naming two
identifiers and asserting two records, and one reusing one identifier and asserting the
replacement, which is the honest statement of the shipped behaviour.

**Why it is deliberate, and why W7E did not change it:** an idempotency key that produced a second
record for a retried request would make a retry indistinguishable from a second execution, which
is precisely what an idempotency key exists to prevent. The key is therefore the right design; the
finding is that the identifier's uniqueness is a *caller* obligation, and nothing in the AI Head
enforces it.

**Consequence for a consumer:** a gateway that resolves an audit record by the caller's request
identifier is reading the latest execution under that identifier. A caller that replays a request
identifier after changing the request will overwrite the evidence for the first one. W7F must
either mint a distinct identifier per execution or state the idempotency contract to its callers.

**Recommended later owner:** **W7F / AI Gateway**, as part of the caller-facing idempotency
contract. It is a caller-contract decision, not an operations one.

**Enforcement status:** unchanged. W7E records the evidence and the audit record once per
execution, as before.

---

## Summary table

| Item | Subject | Recommended owner | Enforcement changed by W7E |
|---|---|---|---|
| CF-1 | writes require approval, unconditionally | W7G / Tool Governance | no |
| CF-2 | agent tool allow-list is declarative | W7G / Tool Governance | no, and not weakened |
| CF-3 | no per-item tenant scoping on context | W7D follow-up / Context Provenance | no |
| CF-4 | `TouchesSurface` unreachable from a turn | W7B follow-up / Prohibition Register | no |
| CF-5 | AI_ROLES divergence report, not pin | none — intended | no |
| CF-6 | `IUsageMeter`/`UsageRecord` are Platform types | Platform contract plane | no |
| CF-7 | historical credential rotation | Human Owner | no |
| CF-8 | `ModelNotRegistered` unreachable | none required | n/a |
| CF-9 | a reused request identifier replaces its audit record | W7F / AI Gateway | no |
