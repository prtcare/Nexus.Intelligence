# W7F — Carry Forward

What W7F deliberately did not close, and why. Each item names its evidence, the reason it was left,
and what a later lane would need in order to close it. Written at the end of `[A5]`, the last
change-capable step of the lane.

**Status at the time of writing:** the AI Gateway lane (`[A]`) is complete and committed on
`w7f/ai-gateway`. The consumer lanes (`[B]` Forge, `[C]` Products) are **not started**, and neither is
W7G — the directive is explicit that W7G does not begin automatically.

---

## 1. Open items that are the AI Head's own

### 1.1 `AiHealthSnapshot` cannot be serialised by `System.Text.Json`

**Finding.** `AiHealthSnapshot.Models` is `IReadOnlyDictionary<(string ModelId, string ProviderId),
AiModelHealthState>`. A `ValueTuple` is not a supported dictionary key, so serialising a snapshot
throws:

```
System.NotSupportedException : The type 'System.ValueTuple`2[System.String,System.String]' is not a
supported dictionary key using converter of type 'System.Text.Json.Serialization.Converters.
ObjectDefaultConverter`1[...]'. Custom converters can add support for dictionary key serialization by
overriding the 'ReadAsPropertyName' and 'WriteAsPropertyName' methods.
```

**Why it matters.** It is not a hypothetical: the throw happens at *response* time, on the first estate
whose snapshot is not empty — which is every estate that works. A test written against an empty
snapshot passes.

**What W7F did.** `OperationsEndpoints` projects the snapshot onto flat `AiHealthRow` records
(`ProviderId`, nullable `ModelId`, `State`) rather than publishing the snapshot itself. The projection
is load-bearing, not cosmetic, and the `[A5]` mutation control proved it: the mutation that appended
the raw snapshot to a rendered response failed with the exception above.

**What remains open.** `AiHealthSnapshot` is still an unserialisable type reachable from any transport
that is handed it, and nothing in the type prevents a later lane doing exactly what the mutation did.
The projection is currently a convention in one file. Closing this properly means either a
`JsonConverter` for the tuple key, or a snapshot type whose wire shape is explicit — a shape change to
a W7E type, which is not a W7F edit.

### 1.2 The operations surface has no authorization layer

**Finding.** `OperationsEndpoints` maps under `/intelligence/operations/v1` exactly as openly as the
turn routes beside it. There is no authentication, no authorization policy, no scope check and no
operator identity anywhere in this estate's API project.

**Why it matters.** This surface names providers, models, health states, reliability per route, spend,
routing rejections and governance outcomes. None of it is *secret* — no handler reads, holds or
returns a credential, and `AiAuditRecord` carries content hashes rather than content, which is checked
below — but "not secret" is not "not sensitive". An unauthenticated caller reading provider health and
committed spend is reading the estate's operational picture.

**What W7F did.** Two things, neither of which is a fix. It gave the surface its own route prefix so
that the operator/caller distinction is a property of the URL rather than of the response body, and it
exposed only scalar query filters, withholding the status-set, failure-category-set and basis-set
filters the read model supports. A narrower transport over a wider read model is the right shape for a
surface that cannot yet tell who is asking.

**What remains open.** Everything else. Inventing an ad-hoc scheme inside a transport file is how an
estate ends up with two of them, so the gap is recorded rather than papered over. Closing it is a
Platform governance act, not an AI Head edit.

**Note on the audit record, verified rather than assumed.** `AiAuditRecord`'s context references carry
`ContextItemId`, `Classification` and `ContentHash`; the record carries `ResultHash` and
`ResultReference`, not the result. So publishing it does not publish prompt or completion content. That
was checked before the route was written, because "the audit record" and "the request log" are
different things and only one of them is safe.

### 1.3 `AiAvailabilityReason.ReliabilityBelowThreshold` is unused

**Finding.** The member exists in the vocabulary and nothing produces it.

**Why.** `GovernedAiOperationalEligibility` already refuses the *route* rather than the *Head* on
reliability grounds. Re-deriving a Head-level reliability verdict inside
`AiGatewayAvailabilityProjection` would make two components the authority for one judgement, and the
projection could then answer "unavailable" about a Head that was about to serve the request.

**What remains open.** The projection reads the health snapshot and the capability register only.
Producing this reason needs a reliability signal that is *route-count-free* — one that says whether
the Head as a whole is below threshold without disclosing how many routes it has, because a Head with
one route and a Head with nine must not be distinguishable through this contract. No such signal
exists, and inventing one is a registry change rather than a gateway change.

### 1.4 The capability register is the governance policy's register

**Finding.** `AiCapabilityRegister` is registered as
`provider.GetRequiredService<AiGovernancePolicy>().Capabilities` — the policy's own instance, taken
rather than constructed.

**Why this is correct.** A capability cannot be advertised by the gateway to a caller and simultaneously
be unknown to the engine that would have to permit it; one source means the two questions cannot
disagree.

**What remains open.** It also means the capability register is not independently replaceable. A lane
that wants a registry-sourced capability register — as W7C did for models, providers, agents, tools and
prompts — must change where `AiGovernancePolicy.Default()` gets `Capabilities` from, in W7B's file. It
is recorded because a reader who expects `AiCapabilityRegister` to be a composition-root choice, as
every other register is, will not find one.

### 1.5 No structured-output mode on the governed path

**Finding.** `AiCapabilityRequest` carries a structured-response contract and `AiCapabilityResponse`
has a `StructuredOutput` member. Nothing on the governed path produces one: the gateway projects
`StructuredOutput = null` on every response.

**Why.** `IGovernedTurnExecution`'s outcome carries composed text and citations and has no
structured-output member. Filling this in would mean either a new member on a W7D outcome type or a
second response path, and neither is a W7F edit. It is a **recorded carry-forward on the gateway**,
visible in the code, rather than a silently-absent field.

### 1.6 Citation derivation is now shared, and that is a deliberate coupling

**Finding.** `CitationExtractor` was extracted from `ResponseComposer` in `[A4]` so the gateway and the
turn path derive citations by the same rule.

**Why.** The derivation was correct and unreachable where it lived; a copy would have been a second
definition of the marker pattern, and the two would have agreed until the first time one changed —
after which the turn path and the capability path would report different citation lists for identical
model output.

**What remains open.** The extraction is not purely mechanical: `ResponseComposer` now calls out, and a
later change to citation semantics has two call sites to consider even though it has one definition.
That is the intended trade and it is recorded so the second call site is known about rather than
discovered.

### 1.7 Caller-stated tool constraints are accepted and are not authorities

**Finding.** `AiCapabilityRequest.Tools.MaxSideEffect` and `RequireApprovalForWrites` are read by the
gateway and passed across as an *offer*. They are not authorities.

**Why.** `GovernedTurnExecution` derives the effective profile from the AI tool registry's own
classification of whatever was offered, so a caller that understates its ceiling or turns off write
approval is either refused by the approval gate or served at the registry's classification — never
served at the lower number it typed. A `[A4]` test asserts the refusal with a side-effect-permitting
requester and a control asserts the same caller offering nothing is served normally.

**What remains open.** Nothing by itself, but the property is structural and therefore worth naming: a
future caller-facing type that *did* treat these as authority would silently widen every consumer's
permissions. The guarantee lives in `GovernedTurnExecution`, not in the request type.

### 1.8 `CapabilityId` could not be read by `System.Text.Json`, so the Gateway rejected every caller

**Finding.** `CapabilityId` holds a `private` constructor — the only way to obtain one is
`CapabilityId.TryParse`, so an unvalidated identifier cannot exist. That is correct for the type and
unreadable by the serialiser, which requires a parameterless, a singular parameterised, or a
`[JsonConstructor]`-annotated constructor. With none of those, `System.Text.Json` refuses the type
outright:

```
System.NotSupportedException : Deserialization of types without a parameterless constructor, a
singular parameterized constructor, or a parameterized constructor annotated with
'JsonConstructorAttribute' is not supported. Type 'Nexus.Intelligence.Contracts.CapabilityId'.
```

**Why it matters.** `GatewayEndpoints` binds `AiCapabilityRequest` straight from the request body —
a deliberate choice, documented in the file, so that there is no third wire DTO to keep in step. The
consequence is that the whole invoke route answered **`400` to every well-formed request**, and no
caller in any repository could have read an `AiCapabilityResponse` either. The Gateway was not
degraded; it was inert.

**Why nothing caught it.** Every W7F test built a contract as a C# object. `W7fGatewayTests` composed
the real governed path and asserted on returned objects; `W7fHttpSurfaceTests` walked the composed
route table without ever sending it a body. Both are satisfied by a contract that serialises but does
not deserialise, because serialisation is the direction that worked — the default converter happily
*writes* `{"value":"code.review"}` for a record with one public property. The defect lived precisely in
the segment no test crossed.

**What W7F did.** Added `CapabilityIdJsonConverter`, applied by `[JsonConverter]` attribute on the
type rather than left for each consumer to register — three repositories read these contracts, and a
consumer that had to remember would eventually not. The wire form is now a plain JSON string, which
is also what the type documents for itself. This is safe as a shape change *because the object form
was unreadable by anything, including this Head*, so no working consumer can depend on it.

Consequences on the read path, which are the point of the fix:

- `AiCapabilityRequest` binds. `POST /invoke` serves instead of refusing.
- `AiCapabilityResponse` reads, so `HttpIntelligenceClient.InvokeAsync` can return a served answer.
- `IReadOnlyList<AiCapabilityRegistration>` reads, so `ListCapabilitiesAsync` works — the one method
  with no failure channel through which to report that it could not read the estate.

Two suites now cross the segment that was untested: `W7fGatewayWireTests` round-trips the contracts
using the same configuration the server binds with, and `W7fGatewayHttpBindingTests` starts Kestrel and
POSTs a body at the real route. `AiJsonConfiguration` was extracted from `Program.cs` so the server and
the tests that prove the server works cannot configure JSON differently — that divergence is what
allowed this to ship.

**What remains open.** Nothing for this defect. The reason it is recorded here rather than closed
silently is that it is a *class* of defect, not an incident: any contract member added later whose type
is not round-trippable reintroduces it, and the two new suites are the only thing standing in the way.
A future lane adding a contract type should check it is readable, not merely writable.

### 1.9 A refused request body produces a `400` with an empty body

**Finding.** A capability identifier that fails to parse inside the request body is refused with
`400` and **no response body**. Sending `{"capability":{"value":"code.review"}}` or
`"code.review.v2"` both produce an empty `400`.

**Why it matters.** The refusal is correct and the request never reaches the gateway — the two
properties that actually matter, and both are asserted. But the *reason* is discarded: the converter
throws a `JsonException` carrying `CapabilityId.TryParse`'s own explanation, and ASP.NET Core produces
the status from the parameter-binding failure without surfacing the inner reason. The codebase calls
this shape out in its own words elsewhere — `GatewayEndpoints` refuses a malformed identifier on the
availability route with `Results.Problem(..., detail: reason)` precisely because "an empty 400 is the
shape that teaches a consumer to retry". The invoke route has the same failure with none of the
explanation.

`AddProblemDetails()` is registered by `Program.cs` and does not close this: a parameter-binding
failure is not an unhandled exception and does not route through the problem-details middleware.

**What W7F did.** Asserted the refusal and the non-execution, and recorded the empty body as a known
rough edge in `W7fGatewayHttpBindingTests` rather than deleting the assertion. The test asserts the body
is empty *today* and states that if a later change gives it a problem-details body, the note is stale
and this item is done.

**What remains open.** Surfacing the parse reason on a body-binding failure — most likely an
`IExceptionHandler` or a filter that catches the binding failure and writes problem details. It is a
consumer-experience item, not a correctness one: nothing is executed and nothing leaks.

---

## 2. Dangling reference, recorded rather than repaired by assertion

**Finding.** `IAiCapabilityClient.ListCapabilitiesAsync`'s remarks cited
`W7A_EXISTING_CODE_RECONCILIATION.md` as the record of the `/intelligence/v1/capabilities`
remediation. **That document does not exist.** `docs/` contains `W7C_FORGE_AI_ROUTING_RECONCILIATION.md`,
`W7E_CARRY_FORWARD.md`, `W7E_PARALLEL_PLAN.md` and `W7F_PARALLEL_PLAN.md`, and nothing else.

**What W7F did.** The remediation was decided and performed — see `§6.1` of `W7F_PARALLEL_PLAN.md` —
and the dangling citation was replaced with a pointer to `CapabilitiesEndpoints`'s own remarks, which
is where the decision now actually lives.

**What remains open.** Whether a W7A reconciliation document was ever written under another name, or
whether the reference was aspirational from the start, is not established. The claim it was cited for
is now recorded in two real places, so nothing rests on it; but a reader who follows W7A-era
citations elsewhere may find the same dangling name again, and this note is the record that at least
one existed.

---

## 3. Consumer lanes — status after this lane

### 3.1 `[B]` — Forge adapter

**Done.** Commit `957d928056e45b58e9b27b898ed6bd4eaeadc502` on `w7f/forge-ai-gateway-adapter`
(worktree `D:/Nexus/Forge/.forge/worktrees/w7f-ai-gateway-adapter`, BaseSHA
`6fdef596e65e5994ee8a7afc2c0ce31b909243f8`). `AiCapabilityClient.ps1` was a file-path locator into the
AI Head's *implementation* — it resolved capability names to source paths inside the AI Head, which
TASK 8 forbids in every part — and is now a gateway client. `Get-AiProviderHealthProbe`,
`Test-AiCapabilityAvailable` and the provider-health policy map were deleted outright.

**What was NOT done, and why.** The 27-entry implementation-path map was **pruned to 26 and
quarantined, not removed**. Deleting it would have converted the graceful `$null` degradation of
Forge's remaining internal consumers into `CommandNotFoundException` under `StrictMode`, so it is
renamed `$script:AiImplementationPaths` and announced at runtime as a legacy annex. WorkflowEngine's
13 resolutions and 12 dot-sources, `deepcode.ps1`, `Test-DbM30` and `Test-DbM33` remain as recorded
violations with exact call sites in
`DevBridge/design/W7F_FORGE_BOUNDARY_CARRY_FORWARD.md` §2. Forge's regression run was byte-identical
to its baseline (`256 passed, 6 failed`, the six pre-existing and caused by `NEXUS_AI_HEAD_ROOT`
being unset on this machine).

### 3.2 `[C]` — Products / Experience

**Done.** Commit `465d6bd` on `w7f/experience-ai-gateway-adapter` (worktree
`D:/NEXUS/Products/Experience/.forge/worktrees/w7f-ai-gateway-adapter`, BaseSHA
`2480d74ab04257d34cfd60cba94aa5056748af62`). `HttpIntelligenceClient` now implements both
`IIntelligenceClient` and `IAiCapabilityClient` over one transport, registered once and projected onto
both interfaces. The containment defect TASK 9 names is fixed: an AI outage reached Chat users as an
unhandled 500 because `SendChatHandler` called the client with no try/catch while the client threw on
every non-2xx. A third defect was found while writing the tests — a malformed 200 body escaped as a
raw `JsonException`, breaking `IAiCapabilityClient`'s "returns rather than throws for every AI-side
failure" — and is now contained as `AiFailureCategory.InvalidOutput`.

**BaseSHA note.** This lane is based on the **unmerged** `w6b/product-vendor-boundary` tip, because
the vendor boundary guard that enforces TASK 9 and TASK 10 exists only there. **W6 must merge before
or with W7F.**

**Package publish: done.** `Nexus.Intelligence.Contracts` `0.1.0-dev.20260913224015` is published to
`nuget.pkg.github.com/prtcare` and is the version lane `[C]` verified against. It supersedes
`0.1.0-dev.20260913222039`, which does **not** contain the `CapabilityId` wire-read fix in §1.8 and
cannot be used by a consumer that reads a capability response. Consumers take a floating `0.1.0-*`;
resolving the superseded build needs the NuGet HTTP cache and the package folder cleared.

### 3.3 `[C-Developer]` — Developer adapter

**No change made, and that is the correct outcome.** Developer has **no runtime AI implementation**:
no `Nexus.Intelligence.*` reference in any `.csproj`, no provider SDK, no AI client, no capability
call. TASK 10 states the rule for exactly this case — "Do not force new Developer AI usage merely to
populate an adapter" — so adding a client class with no caller would have been the thing it forbids.

The prohibitions TASK 8 and TASK 10 state for a consumer are **already enforced** for Developer by
`tests/Nexus.Developer.Core.Tests/VendorBoundary/ProductVendorBoundaryGuard.cs` and
`VendorBoundaryGuardTests.cs`, which refuse vendor AI SDKs and every `Nexus.Intelligence.*` reference
except `Nexus.Intelligence.Contracts`. Verified: 17 passed, 0 failed. The permitted seam therefore
already exists, and a future Developer function requests `architecture.review`, `code.review`,
`code.generate` or `test.diagnose` through `Nexus.Intelligence.Contracts` with no provider or model
knowledge.

**One adjacent finding, recorded not repaired.** `src/Nexus.Developer.Client.Legacy/config/layers.json`
names layer 04 "AI" with `path: C:\Personal\Nexus.Intelligence`, consumed by `NexusDev.ps1` (line 16)
for a dashboard git-status read (`Get-GitInfo -RepoPath`) and open-folder buttons. It is a
developer-tooling repository locator, not a capability call, and it is stale legacy — the whole file
uses `C:\Personal\*` paths that do not exist on this machine. Not a TASK 10 violation, but if the
Legacy client is ever revived, this is the entry that would point it at the AI repository.

---

## 4. Constraints that remain in force after this lane

- **`REQUIRES_HUMAN_SECRET_ROTATION` remains active.** The historical provider credential was not
  activated, tested, read, copied, printed or referenced anywhere in W7F or its tests. Every gateway
  and operations test terminates at a governed fake provider or at a port with no provider behind it;
  no default, fixture or configuration entry names `NEXUS_OPENAI_API_KEY`; and nothing in the lane
  required a live credential.
- **`NEXUS_OPENAI_API_KEY` remains the approved default secret reference** and is not replaced with a
  vendor-conventional name.
- **No `Nexus.Platform.Providers.OpenAI` under Platform.** W7F did not touch the provider tree. The
  `src/Nexus.Platform.Providers.OpenAI` project in this repository is the W5G-relocated AI-Head-side
  sibling, not a Platform provider project.
- **Provider and model remain AI-owned.** They may appear on the operations read surface behind the
  gateway; they may not appear on `AiCapabilityResponse`, and `[A4]`'s tests assert the projection
  rather than the intention.
- **No second router and no second provider invocation path.** The gateway translates and projects; it
  does not execute. `AiCapabilityGateway` holds `IGovernedTurnExecution` and no model step, no model
  gateway, no endpoint and no credential.
- **STOP after W7F. W7G is not started.**

---

## 5. What W7G must prove

W7F established that a caller can ask for a capability without naming a provider or a model, and that
the AI Head owns that choice. It did **not** establish that the choice can be changed safely. W7G must
prove, deterministically and without a live credential:

### 5.1 Provider interchangeability

That a provider can be added, removed or replaced **without any consumer change and without any
contract change** — because no consumer-facing type can express a provider at all. The proof is not
"the tests still pass"; it is that the consumer-facing types are *incapable* of naming one, which is a
property of the types and must be asserted structurally, as `W7fGatewayBoundaryTests` already begins to
do. W7G must show a second provider serving the same capability behind the same frozen contract, with
the consumer's code byte-identical.

### 5.2 Provider / model swap

That a routing configuration change moves live traffic from one route to another with **no consumer
rebuild and no contract version change**, and that the swap is *visible* to operators (through the
operations read surface, as execution evidence) and *invisible* to callers. This needs a deterministic
proof that the same semantic request served by two different routes produces responses that differ by
nothing a caller can observe — including in the failure taxonomy, which must stay provider-neutral.

### 5.3 Degraded mode

That a partially-usable estate produces `AiAvailabilityState.Degraded` with a
`AiExecutionStatus.Degraded` execution rather than a refusal or a silent full-quality claim, and that a
caller which asked to be failed instead of degraded gets exactly that. `[A4]` tested the caller-visible
half (`IsDegraded`, and the `OnDegradation is Fail` branch); W7G must prove the estate-side
conditions — reduced redundancy, a route that is `RateLimited` or `Degraded`, an unpriced fallback —
each produce the state they claim to.

### 5.4 AI removal

That the estate runs with the AI Head **entirely absent** and every `AI_DEPENDENT` consumer degrades
into its controlled typed failure rather than into an exception, a retry storm or a hang; that
`AI_OPTIONAL` and `AI_ENHANCED` consumers continue on their deterministic paths; and that no unrelated
functionality of any consumer is affected. This is the strongest of the six, because it is the one
where a boundary that is only nominally a boundary fails: it requires the consumers to actually treat
`AI_UNAVAILABLE` as a normal answer.

### 5.5 Failover

That a failing primary route falls over to an alternate and that the failover is (a) recorded once, in
the right place, (b) separately attributable per attempt, (c) reflected to the caller only as
`UsedFallback = true` with no route identity, and (d) reflected to operators as the full attempt list.
The `[A4]` tests cover the caller-facing half; the `AttemptId` distinction added by TASK 2 exists for
the operator half and its failover-specific evidence is not yet exercised end to end.

### 5.6 Recovery

That a route which failed and then recovered is *routable again* — that reliability evidence ages out
or stops gating as configured, that a circuit that opened closes, and that the recovery is visible in
availability without a restart. This is the one that most easily passes by accident, because a test
that only ever exercises the failing path cannot distinguish "recovered" from "never actually
gated". It needs a clock the test controls and a mutation control proving the gate was closed at the
point recovery was asserted.

### 5.7 The through-line

Each of the six must be provable **without a live provider credential**, at a governed fake provider,
with the swap/failover/removal performed by configuration and not by code. If any of the six requires a
code change to demonstrate, then W7F's boundary is incomplete and W7G's job is to report that rather
than to demonstrate the swap anyway.

### 5.8 A precondition that did not hold until this lane

W7G's six proofs all travel over the capability wire, and until commit `7a30be8` **that wire could not
carry them**: `CapabilityId` was unreadable by `System.Text.Json`, so `POST {RoutePrefix}/invoke`
answered `400` to every well-formed request and no consumer in any repository could have read an
`AiCapabilityResponse`. See §1.8. Every one of the six would have been unprovable for a reason that
had nothing to do with the property being proved, and the failure would have looked like a swap that
did not take effect.

Two consequences W7G should carry:

- The six are now demonstrable, and a W7G attempt that fails should be read as a real finding rather
  than a leftover of this defect. `W7fGatewayWireTests` and `W7fGatewayHttpBindingTests` are what
  establish that, and they are the tests to re-run first if a wire failure appears.
- The defect was invisible to every in-memory test. Any W7G harness that composes the governed path as
  objects without crossing HTTP inherits the same blind spot. **Cross the wire at least once per
  property.**
