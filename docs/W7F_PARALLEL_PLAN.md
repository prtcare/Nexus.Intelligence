# W7F — Parallel Plan

**Lane:** W7F — AI Gateway/API + consumer adapters
**Branch:** `w7f/ai-gateway`
**Worktree:** `D:/Nexus/AI/Intelligence.work/w7f-ai-gateway`
**BaseSHA (new):** `99f501344e686733872d5bd17e63260fe6dd75a4` (accepted W7E)
**BaseSHA (old):** N/A — no pre-existing W7F worktree or branch was found (`git branch -a | grep -i w7f`
and `git worktree list | grep -i w7f` both returned nothing), so this is a clean creation from the
accepted W7E commit rather than a rebase. Nothing was recreated and no history was rewritten.
**Rollback point:** `99f5013` — identical to BaseSHA; it is the first W7F commit's parent.

The W7E SHA the directive names resolves (`git cat-file -t 99f501344e686733872d5bd17e63260fe6dd75a4`
→ `commit`). No discrepancy this time; the parent-commit correction W7E had to record does not recur.

---

## 1. The finding that reshapes this lane: the contract is already frozen

The directive's proposed order is:

```
W7F-A Gateway contract/API
         ↓
    ┌────┴────┐
    ↓         ↓
W7F-B       W7F-C
Forge      Products
```

and instructs: *"Verify against actual ChangeScopes before execution."* Verified, it does not hold
as written, and the difference is favourable rather than blocking.

**W7A already froze the public Gateway contract.** `Nexus.Intelligence.Contracts` at BaseSHA
contains:

| Directive task | Already-frozen contract | File |
|---|---|---|
| TASK 1 — public gateway contract | `IAiCapabilityClient`, `AiCapabilityRequest`, `AiCapabilityResponse` | `Client/IAiCapabilityClient.cs`, `Capabilities/AiCapabilityRequest.cs`, `Results/AiExecutionReference.cs` |
| TASK 2 — execution identity model | `AiExecutionResult` carries **distinct** `RequestId` and `ExecutionId`; `AiExecutionReference` is the opaque caller handle | `Results/AiExecutionResult.cs` |
| TASK 3 — response contract | `AiCapabilityResponse` — output, usage, cost, timing, policy, evaluation, failure, opaque execution reference, audit reference, `IsDegraded` | `Results/AiExecutionReference.cs` |
| TASK 11 — failure vocabulary | `AiFailureCategory` — the directive's eleven categories, member for member | `Failures/AiFailureCategory.cs` |

`AiCapabilityRequest` carries **no provider, model, endpoint or credential field**, and its own
remarks say so as a structural claim: *"a caller cannot pin a model because there is nowhere to
write one."* TASK 1's "must NOT require ProviderId/ModelId/provider endpoint/provider credential"
is therefore already satisfied at the type level, and W7F must not restate it as a new contract.

**So W7F-A is an API, not a contract.** The contract is frozen; the *server* that serves it, the
*projection* from the governed path onto it, and the execution-identity correction behind it are
not written. That is the lane.

### 1.1 Consequence for the dependency graph

Because the contract plane is already stable, **W7F-B and W7F-C are contract-safe from the first
commit** — they do not have to wait for W7F-A to freeze anything. What they must wait for is the
**wire surface** (routes, paths, version token) and the **published package** (§3). Those are
W7F-A's outputs, so the directive's serialisation of A before B/C is correct for the right reason,
even though its stated reason ("only after the Gateway contract is frozen") is already discharged.

---

## 2. Verdict

**Lanes A, B and C are NOT collision-safe as stated, for three independent reasons — and one of
them is a hard blocker on C that no scheduling fixes.**

| Lane | Repository | ChangeScope |
|---|---|---|
| A — Gateway/API | `D:/Nexus/AI/Intelligence` | AI Head contracts, Core, Api, tests |
| B — Forge adapter | `D:/Nexus/Forge` | `DevBridge/scripts/ai-boundary/**`, `NexusDev.ps1` |
| C — Product adapters | `D:/Nexus/Products/Experience`, `D:/Nexus/Products/Developer` | Chat infrastructure + architecture tests |

A, B and C live in **three separate Git repositories**. That is a stronger separation than W7E's
sub-lanes had and it removes the file-collision class entirely: no path under one lane's ChangeScope
is reachable by another. It does **not** remove the other three collision classes.

### 2.1 Contract collision — `Nexus.Intelligence.Contracts` (blocking for C)

The standing V3 rule is:

> No two lanes may add a type to `Nexus.Intelligence.Contracts` in the same integration window.

W7F is *one* lane, so its own additions are not a lane-vs-lane breach. But
`Nexus.Intelligence.Contracts` is **published to GitHub Packages and consumed by every Product via
a floating `0.1.0-*` version**, so an addition here is not a private act: it is a change to what
every consumer resolves on its next restore.

This is the second collision class, and it is the one that decides C.

### 2.2 Publication collision — the consumed package predates W7A (blocking for C)

Verified, not inferred:

- `src/Nexus.Products.Chat.Application/obj/project.assets.json` resolves
  `Nexus.Intelligence.Contracts/0.1.0-dev.20260825143627`.
- That assembly, read from the global package cache, contains `IIntelligenceClient` and
  `IntelligenceTurnRequest` and **none** of `IAiCapabilityClient`, `AiCapabilityRequest`,
  `AiCapabilityResponse`, `AiExecutionResult` or `AiFailureCategory`.

The resolved package is **pre-W7A**. No consumer can compile against the Gateway contract until a
package containing it is published. Publishing is `pack-local.ps1`, which pushes to
`nuget.pkg.github.com/prtcare`.

**Decision taken (Human Owner, this session): republish the package.** Consequences recorded
because they are broader than C:

- Every repository floating `0.1.0-*` moves onto the new package on its next restore — including
  `Products/Developer` and the four `Experience-*` sibling worktrees, none of which W7F is adapting.
- The publish is **outward-facing and not reversible** by a revert: a published NuGet version cannot
  be unpublished by `git revert`. The rollback point for the package is a *new* version, not a
  commit.
- The package is packed from the W7F worktree's `Nexus.Intelligence.Contracts`, so **the package's
  contents are W7F's contents**. A contract added by W7F and then reverted in Git would still be in
  the published version. This is stated here rather than discovered later.

### 2.3 Produce/consume collision — C consumes what A produces (serialising, not blocking)

`HttpIntelligenceClient` cannot be adapted to `IAiCapabilityClient` before that interface exists in
a package the consumer can resolve. C is therefore **serial after A's contract additions are final
and packed**. It is additionally serial after A's wire surface is fixed, because the HTTP
implementation has to call something.

### 2.4 Boundary collision — B and C do not collide with each other

Forge is PowerShell in its own repository; the Products are C# in theirs. They share no file, no
project, no package and no build. **B and C are genuinely parallel-safe with respect to each other**
once A is done. That is the one place the directive's proposed split holds unamended.

### 2.5 The Forge change is not the change the directive describes (scope correction)

TASK 8 reads as though Forge has a client that needs re-pointing. It has a **file-path locator**.
`DevBridge/scripts/ai-boundary/AiCapabilityClient.ps1` maps capability names onto paths *inside the
AI Head* and dot-sources them:

```
'ModelCatalogue'           = 'config\models.json'
'PricingCatalogue'         = 'config\pricing\pricing-catalogue.json'
'Router'                   = 'ai-routing\router\Router.ps1'
'RoutingPolicy'            = 'ai-routing\router\RoutingPolicy.ps1'
'ProviderHealthProbe'      = 'ai-routing\provider-health\ProviderHealthProbe.ps1'
'ModelConfigEngine'        = 'ai-routing\model-config\ModelConfigEngine.ps1'
'ProviderLaunchEnvironment'= 'ai-routing\providers\launch\ProviderLaunchEnvironment.ps1'
```

Every one of those is something TASK 8 forbids: *"must not reference provider projects; select
models/providers; inspect registry internals; inspect provider health directly; read AI
implementation storage directly."* `Get-AiProviderHealthProbe` is a direct provider-health reach.

**Decision taken (Human Owner, this session): re-point at the Gateway only.** The implementation-path
capability map is removed and replaced by semantic capability invocation. This is a larger Forge
change than "adapt a client", and it is the change TASK 8 as written requires.

---

## 3. Serial dependency graph

```
   [0] pre-flight: worktree from accepted W7E commit          <- done
            |
   [A1] execution identity (ExecutionId != RequestId)          <- Core, no contract change
            |
   [A2] budget + unpriced-route semantics (TASK 4, 5)          <- contracts, additive
            |
   [A3] gateway contract additions (TASK 1, 3, 14)             <- contracts, additive
            |
   [A4] the Gateway: projection + translation (TASK 2, 11, 13)
            |
   [A5] HTTP surface: capability, operations, availability     <- Api (TASK 6, 7, 15, 16)
            |
   [P]  pack and publish Nexus.Intelligence.Contracts          <- outward-facing
            |
     +------+------+
     |             |
   [B] Forge     [C] Products
     |             |
     +------+------+
            |
   [V] regression: W7B, W7C, W7D, W7E, gateway, adapters       (TASK 17)
```

`[A1]` is first and alone because it changes `GovernedTurnExecution`, which W7B/W7C/W7D/W7E tests
all construct. Landing it before the contract additions means one rebuild of the existing suites
rather than two.

---

## 4. What is theoretically parallel-safe

Recorded as the directive requires, for a future window with more than one executor:

1. **B and C are parallel-safe with each other**, unconditionally, once A is complete: different
   repositories, different languages, no shared file or package.
2. **A's test files are parallel-safe with A's implementation** by directory convention
   (`tests/Nexus.Intelligence.Tests/Gateway/**`, `tests/Nexus.Intelligence.Architecture.Tests/W7f*.cs`),
   provided the contract additions `[A2]`/`[A3]` land first — they are the vocabulary both sides
   name.
3. **Not parallel-safe under any partitioning:** `[A2]`/`[A3]` (one vocabulary, one window), `[A4]`
   (single seam: `GovernedTurnExecution`), `[A5]` (single file: `Program.cs` and the composition
   root), and `[P]` (one package, one version stream — two concurrent packs produce two versions,
   the later of which silently wins for every floating consumer).

---

## 5. This session's execution

One executor, so per the directive it executes sequentially:
**[A1] → [A2] → [A3] → [A4] → [A5] → [P] → [B] → [C] → [V]**, committed in stages so each rollback
point is meaningful rather than one commit at the end.

**Lane order is A, then B, then C** rather than B and C together, for one reason: `[P]` republishes
a package every floating consumer resolves, and C is the only lane that can verify the result of
that publish. Verifying it before touching Forge means a publish failure is found while the diff is
still small.

---

## 6. Reserved ChangeScope

No file outside this list is modified by W7F. A change outside it is a scope breach and must be
reverted rather than explained.

**AI Head — new, contracts (additive only; no existing member is renamed, removed or renumbered)**
- `src/Nexus.Intelligence.Contracts/Gateway/**`

**AI Head — new, implementation**
- `src/Nexus.Intelligence.Core/Gateway/**`
- `src/Nexus.Intelligence.Core/Operations/AiExecutionIdentity.cs`

**AI Head — new, API surface**
- `src/Nexus.Intelligence.Api/Endpoints/GatewayEndpoints.cs`
- `src/Nexus.Intelligence.Api/Endpoints/OperationsEndpoints.cs`

**AI Head — new, tests**
- `tests/Nexus.Intelligence.Tests/Gateway/**`
- `tests/Nexus.Intelligence.Tests/Operations/W7f*.cs`
- `tests/Nexus.Intelligence.Tests/Turns/CountingAiExecutionIdSource.cs`
- `tests/Nexus.Intelligence.Architecture.Tests/W7f*.cs`

**AI Head — modified**
- `src/Nexus.Intelligence.Core/Turns/GovernedTurnExecution.cs` (execution identity; the TASK 2 site)
- `src/Nexus.Intelligence.Api/DependencyInjection/IntelligenceServiceCollectionExtensions.cs`
- `src/Nexus.Intelligence.Api/Program.cs`
- `src/Nexus.Intelligence.Api/Endpoints/CapabilitiesEndpoints.cs` (TASK 13 leak, TASK 14 version)
- `src/Nexus.Intelligence.Api/appsettings.json` (only if a gateway setting is genuinely required)
- `src/Nexus.Intelligence.Contracts/Operations/AiUsageLedger.cs` (additive: attempt identity)
- `src/Nexus.Intelligence.Contracts/Operations/AiOperationsVocabulary.cs` (additive: `AiBudgetOutcome`, `AiBudgetReading`)
- `src/Nexus.Intelligence.Contracts/Operations/AiOperationsBudget.cs` (additive: `Outcome`, `OnUnpricedExecution`, `AiBudgetSubstitution`)
- `src/Nexus.Intelligence.Contracts/Operations/AiAuditEmission.cs` (additive: `BudgetSubstitution` on the routing evidence)
- `src/Nexus.Intelligence.Contracts/Operations/AiOperationsReadModel.cs` (additive: budget outcome)
- `src/Nexus.Intelligence.Contracts/Results/AiExecutionReference.cs` (additive: `UsedFallback`)
- `src/Nexus.Intelligence.Core/Operations/AiOperationsReadModel.cs` (the two-reading budget fix)
- `src/Nexus.Intelligence.Core/Operations/ConfiguredAiBudgetEvaluator.cs` (TASK 4: every return states an outcome)
- `src/Nexus.Intelligence.Core/Operations/AiOperationsRecorder.cs` (attempt identity threading; TASK 5 substitution)

**AI Head — modified, existing tests**
- `tests/Nexus.Intelligence.Tests/Turns/GovernedPath.cs` (the execution-identity seam on the harness)
- `tests/Nexus.Intelligence.Tests/Operations/W7eFixture.cs` (a remark the TASK 2 change made false)
- `tests/Nexus.Intelligence.Tests/Operations/W7eAuditAndObservabilityTests.cs` (the CF-9 test, inverted)

**Scope additions made after this plan was written, recorded rather than absorbed.** The `[A1]` bullet
above and the test paths in this section were added when the execution-identity design settled, at which
point the port needed a file of its own and the TASK 2 tests needed a home that was not `Gateway/` — the
identity correction is a Core fix and not a gateway one. The three test files under **modified, existing
tests** were not foreseen either: two of them are the harness seam and a remark that TASK 2 falsified, and
the third is the W7E test that recorded CF-9 as shipped behaviour and that TASK 2 necessarily inverts.
That test is inverted rather than deleted so the defect it recorded is still asserted, from the other side.

Four further additions came from `[A2]`, and they are recorded here rather than folded into the list
above because the plan reserved only two contract files for the budget work and the task needed four.
TASK 4 could not be answered inside `AiOperationsReadModel.cs`: a verdict and a rule identifier cannot
say *which* conclusion the gate reached, so the conclusion needed a vocabulary of its own
(`AiOperationsVocabulary.cs`), a member to carry it (`AiOperationsBudget.cs`), and a return site in every
branch of the evaluator that previously returned a bare allow (`ConfiguredAiBudgetEvaluator.cs`). TASK 5's
substitution then needed one member on the routing evidence, which is `AiAuditEmission.cs`. All four are
additive — no member is renamed, removed or renumbered, and every added member has a default that
preserves the meaning of records written before it existed. The plan's own rule is that a change outside
the list is a breach to be reverted rather than explained; these are recorded as scope so that judgement
is made by the reader, not by the executor.

A fifth addition came from `[A3]`, and it is the smallest and the most consequential to argue.
`Results/AiExecutionReference.cs` gained `UsedFallback`, because TASK 3 names "fallback occurred" as
part of the gateway response contract and the frozen W7A response carries no such member. The plan
assumed the contract plane needed no edits at all beyond new files, which §1's table shows was nearly
right; this is the single member it was not right about. It is additive with a default of `false`, and
the argument for putting it on the caller-facing response rather than only on the operations surface is
recorded on the member itself: a caller that has been told to expect a particular quality, or that is
deciding whether to re-ask, is entitled to know its answer came from a secondary route — and it learns
that without learning which route, which is the same arrangement `AiExecutionReference` already makes
for provider and model identity.

`[A4]` — the gateway implementation — produced three changes worth recording. The first is not an addition
to the reserved list so much as a note that the reservation was exact: the gateway's own files landed in
`src/Nexus.Intelligence.Core/Gateway/**` and in `tests/Nexus.Intelligence.Tests/Gateway/**`, both of which
the plan reserved, and no file outside the list was touched by it.

The second is a sixth addition: `Core/Turns/CitationExtractor.cs` (new) plus `Core/Turns/ResponseComposer.cs`
(modified). It needs the argument stated because it is a change to a W7D file in a lane whose subject is
the boundary. **The citation derivation existed in exactly one place, inside `ResponseComposer`, where it
was correct and unreachable.** TASK 3 puts citations on the caller-facing response, so the gateway needed the
same fact — and the two ways to get it were to copy the `[ctx:<id>]` pattern into the gateway or to move
it somewhere both callers read. A copy would be a second definition of what a citation marker is, and the
two would agree until the first time one of them changed, at which point the turn path and the capability
path would report different citation lists for identical model output with nothing to say which was right.
`ResponseComposer` now calls `CitationExtractor.Extract` with the same arguments it used to inline, so its
behaviour is unchanged — same pattern, same admitted-context filter, same first-appearance ordering — and
the W7D suite that already covered citations passes unmodified, which is the evidence for that claim
rather than the assertion of it. The admitted-context filter is the substantive part and it is preserved
deliberately: a model is free to write `[ctx:anything]`, and a citation list built from the model's own
text would let it cite a source that was never sent to it.

The third is a seventh addition, and it is documentation rather than code:
`Contracts/Client/IAiCapabilityClient.cs`'s remarks said "Implementations are transport, not policy",
which the gateway's existence makes half true. The type is
the boundary and it has two roles — a consumer implements it as transport, the AI Head implements it as
the serving role — and the amendment says so, and argues against the parallel server-side port that was
considered and rejected. It is recorded here because a lane that changes code and leaves the documentation
next to it describing the old shape is the same class of defect as a test that asserts an intention: the
next reader trusts the prose.

### 6.1 Scope additions recorded at `[A5]` — the HTTP surface

`[A5]` (TASKS 6, 7, 13, 14, 15 and 16) produced eight changes worth recording, two of which are
outside the scope reserved below and are argued here for the same reason `[A4]`'s two are.

The first is `src/Nexus.Intelligence.Api/Endpoints/CapabilitiesEndpoints.cs`, which is **inside** the
reserved scope but changed in a way the reservation did not anticipate: the route is not repaired but
**retired**, and the two response records it published (`CapabilitiesResponse`, `ModelSummary`) are
deleted rather than left unused. The reservation said "re-point the capabilities endpoint"; the
decision taken is to answer `410 Gone` naming the replacement instead, because the response *shape* is
what a consumer deserialises and a `Models` array narrowed to empty is indistinguishable from an
estate that has no models. A silently-narrowed body is a lie by omission; an addressable refusal is
not. The deleted types are the leak in type form — leaving them would let a later lane re-serve the
exposure by finding a public record already shaped for it.

The second is `tests/Nexus.Intelligence.Architecture.Tests/Nexus.Intelligence.Architecture.Tests.csproj`,
which gains a `<FrameworkReference Include="Microsoft.AspNetCore.App" />`. This is a **test-project
change outside the reserved scope**, and it was not foreseen. `W7fHttpSurfaceTests` composes the API's
route table through `IEndpointRouteBuilder`, and the framework reference does not flow transitively
from the referenced `Microsoft.NET.Sdk.Web` project. The addition is test-only and build-time only;
nothing is packaged from that project and no application assembly gains a dependency.

One further finding from that work is recorded rather than fixed, because it is a property of a type
this lane did not write: **`AiHealthSnapshot.Models` cannot be serialised by `System.Text.Json`.** It
is keyed by `(string ModelId, string ProviderId)`, and a tuple is not a supported dictionary key, so
returning the snapshot directly from the health route throws at response time — on the first estate
whose snapshot is not empty, which is every estate that works. The projection into `AiHealthRow` is
therefore load-bearing rather than cosmetic, and a mutation control confirmed it: the mutation that
appended the raw snapshot to the caller-facing render failed with
`NotSupportedException: The type 'System.ValueTuple\`2[System.String,System.String]' is not a supported
dictionary key`. It is carried into `W7F_CARRY_FORWARD.md` as a hazard for any later lane that
publishes a health snapshot over a wire.

**AI Head — new, documents**
- `docs/W7F_PARALLEL_PLAN.md` (this file)
- `docs/W7F_CARRY_FORWARD.md`

**Forge — modified**
- `DevBridge/scripts/ai-boundary/AiCapabilityClient.ps1`
- `DevBridge/scripts/ai-boundary/*` (new semantic client module, if the boundary needs its own file)
- `NexusDev.ps1` (only if the boundary's wiring point changes)
- Forge's own boundary tests, if the repo has them at the path the boundary change touches

**Products — modified**
- `Products/Experience/src/Nexus.Products.Chat.Infrastructure/Intelligence/**`
- `Products/Experience/src/Nexus.Products.Chat.Infrastructure/ServiceCollectionExtensions.cs`
- `Products/Experience/tests/Nexus.Products.Chat.Architecture.Tests/**`
- `Products/Experience/nuget.config` (only if the resolved version must be pinned)
- `Products/Developer/**` — seam only; TASK 10 forbids forcing new AI usage

---

## 7. Standing constraints carried into this lane

- **`REQUIRES_HUMAN_SECRET_ROTATION` remains in force.** The historical provider credential is not
  read, tested, printed, copied or used by this lane or its tests. `NEXUS_OPENAI_API_KEY` is
  confirmed unset in this environment; no W7F default, probe, fixture or configuration entry
  references it, and no test requires it. The Gateway's own tests terminate at a governed fake
  provider.
- **The publishing credential is a different credential** (`GITHUB_PACKAGES_TOKEN`, a Packages PAT).
  It is used only as the `dotnet nuget push` api-key argument and is never read for display, logged,
  echoed or written to a file.
- **`NEXUS_OPENAI_API_KEY` remains the approved default secret reference** and is not replaced with
  a vendor-conventional name.
- **No `Nexus.Platform.Providers.OpenAI` under Platform.** W7F does not touch the provider tree.
- **Append-only on accepted vocabulary.** `AiFailureCategory`, `AiExecutionStatus`, `AiCostBasis` and
  the routing vocabularies gain no renumbered or removed members.
- **No second router and no second provider invocation path.** The Gateway translates and projects;
  it does not execute. Every capability invocation reaches a provider through
  `IGovernedTurnExecution` or not at all.
- **Provider and model are evidence, never caller authority.** They may appear on the operations
  read surface behind the Gateway; they may not appear on `AiCapabilityResponse`.
- **Atlas is not coupled.** The operations read API is an AI Head HTTP surface; no Atlas-specific
  adapter, type or project is created.
- **STOP after W7F. W7G is not started.**
