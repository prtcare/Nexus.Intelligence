# W7C TASK 6 — Forge AI-routing reconciliation

**Lane:** W7C — Model / Provider Registry + Router
**ChangeScope:** Task 6 only (classification and disposition record). No file under `ai-routing/` was
modified, moved or deleted by this lane.
**Date:** 2026-09-13

---

## 1. The directive's premise, corrected

TASK 6 reads:

> reconcile the migrated Forge AI-routing implementation now residing under AI Head. Classify each
> existing component: KEEP / ADAPT / SUPERSEDE / DEPRECATE. Do not create a second router alongside a
> working migrated router. Prefer adapting the existing tested subsystem behind the new
> registry/governance contracts.

The directive presumes **a working migrated router that W7C should adapt behind the new contracts**.
The verified inventory does not support that reading, and the difference changes what TASK 6 can
produce. Stating it is part of the task, not a way around it.

### 1.1 What is actually there

| Fact | Value | How verified |
|---|---|---|
| Files under `ai-routing/` | **89** | `find ai-routing -type f \| wc -l` |
| PowerShell files | **87** | `find ai-routing -name '*.ps1' \| wc -l` |
| C# files | **0** | `find ai-routing -name '*.cs' \| wc -l` |
| Project files | **0** | `find ai-routing -name '*.csproj' \| wc -l` |
| References to `ai-routing` from any `.cs`, `.csproj` or `.slnx` outside it | **0** | `grep -rn "ai-routing" --include=*.cs --include=*.csproj --include=*.slnx . \| grep -v '^./ai-routing'` |

`ai-routing/` is a **PowerShell implementation with no compiled artefact and no inbound reference**.
It cannot be adapted *mechanically* in C#: there is no callable surface, no project, no test runner
in this solution that would execute it, and no compilation step that would fail if it were deleted.
It is dormant, history-preserved, and deliberately non-executing.

### 1.2 Git provenance confirms the migration was intentional

```
7d55510 W6R2 Lane A: AI-side host resolution, provider health, provider launch
1d3dfd1 W6/LaneA: import the Forge ai-routing unit into the AI Head (part 2 of 2)
968b821 W5E: remove the ai-routing unit's last bound credential read
```

`968b821` is the load-bearing one: the unit's last bound credential read was **removed** before the
W6 import. The unit is not merely unreferenced — it was deliberately severed from the credential path
so that importing it could not re-establish a provider invocation. That is consistent with
`REQUIRES_HUMAN_SECRET_ROTATION` and it is why "re-activate the PowerShell router" is not an option
this lane may take.

### 1.3 What the directive is actually protecting against

> Do not create a second router alongside a working migrated router.

There **is** a working router in this repository, and it is C#. The hazard is real; the directive
located it on the wrong side of the language boundary. The live routing path is:

```
TurnPipeline → ModelStep ─┐
                          ├→ IModelGateway (RoutingModelGateway) → INamedModelGateway → vendor
Planner ──────────────────┘
TurnPipeline → ModelSelector : IModelSelector
```

`ModelSelector`, `ModelStep` and `Planner` route and invoke **without consulting
`IAiCapabilityRouter` or `IAiGovernanceEvaluator`**. Verified:

```
grep -rn "IAiCapabilityRouter\|IAiGovernanceEvaluator" --include=*.cs src/ \
  | grep -v "DependencyInjection\|Core/Routing\|Core/Governance"
→ no results
```

So the "second router" is the **existing live C# path**, and it is second by virtue of being
ungoverned rather than by being new. W7C does not resolve that: the caller's explicit scoping
statement keeps it for W7D/W7E —

> the live TurnPipeline is not yet governed, because it does not currently carry the required
> model/provider/data-classification context. Do not force that into W7C.

### 1.4 The resolution, stated plainly

- The **design** of the migrated unit is ADAPTed — transcribed into C# as the specification the W7C
  router implements, with the W7B governance contracts the PowerShell predates.
- The **PowerShell stays in place, untouched.** Deleting 87 files of history-preserved migrated code
  is destructive, unreviewable in this lane, and outside the ChangeScope the directive granted.
- The **live C# path is classified SUPERSEDE**, scheduled for W7D/W7E, and is *not* deleted, because
  it is live. Deleting it in W7C would break the turn pipeline while its replacement is not yet
  wired.

---

## 2. Classification

Dispositions: **KEEP** = remains as-is, no W7C action. **ADAPT** = its design is transcribed into the
new contracts. **SUPERSEDE** = replaced, with a named successor and a named owner for the rewiring.
**DEPRECATE** = no successor; do not carry forward.

### 2.1 `ai-routing/` — the migrated PowerShell unit

| Component | Files | Disposition | Successor / rationale |
|---|---|---|---|
| `router/` | 11 | **ADAPT** | `GovernedCapabilityRouter` (C#). Near member-for-member match, §3.1. |
| `providers/` | 9 | **ADAPT** | `AiProviderRegistration` + `ConfiguredAiRegistry` (C#). |
| `provider-health/` | 6 | **ADAPT** | `IAiModelHealthSource` + `AiHealthConfigurationEntry`. |
| `escalation/` | 9 | **ADAPT** | `AiGovernanceEscalationRule` + `AiGovernanceVerdict.HumanDecisionRequired` (W7B). |
| `model-config/` | 4 | **ADAPT** | `AiModelConfigurationEntry` + `AiRegistryConfiguration`. |
| `failover/` | 3 | **ADAPT** | Derived fallback chain — `AiRoutingOutcome.FallbackChain`, §3.3. |
| `budget/` | 3 | **ADAPT** | `AiGovernanceBudgetRule` (W7B) + the caller cost ceiling in the router. |
| `calculator/`, `quality-cost/` | 7 | **ADAPT** | Cost prediction in the router's ranking; rate metadata on the registration. |
| `performance/`, `task-history/`, `failure-fingerprints/` | 12 | **SUPERSEDE** | W7E (Operations, Cost, Health). These are *observed-history* inputs; W7C has no probe and no store, and inventing one would be W7C implementing W7E. |
| `dashboard/` | 4 | **SUPERSEDE** | W7F (Gateway/API) / W7E. Presentation over metrics W7C does not collect. |
| Root `*.ps1` foundations | 21 | **DEPRECATE** | Superseded by the registry contracts. `AiRoutingFoundation.ps1`, `AiPricingContracts.ps1`, `ModelCatalogue.ps1`, `PricingCatalogue.ps1`, `AiHostRoot.ps1` and peers are the bootstrap scaffolding the registry replaces; no successor is needed because the C# types *are* the successor. The 21 root scripts plus 66 under the component directories plus 2 JSON fixtures are the 89 files. |
| `config/` (repository root) | 7 | **SUPERSEDE** | `AiRegistryConfiguration` + the committed `appsettings.json`. See §4 — this directory is the migrated unit's data plane and is where the secret-reference disagreement lives. |

**No file under `ai-routing/` was changed by W7C.** The dispositions above are a record, not an edit.

### 2.2 The live C# routing path

| Component | Disposition | Successor | Owner |
|---|---|---|---|
| `Core/Turns/ModelSelector.cs` | **SUPERSEDE** | `GovernedCapabilityRouter.Route` | W7D |
| `Core/Turns/ModelStep.cs` | **SUPERSEDE** | `GovernedProviderInvocation` (W7B) | W7D |
| `Core/Planning/Planner.cs` (via `IModelGateway`) | **SUPERSEDE** | `GovernedCapabilityRouter` + `GovernedProviderInvocation` | W7D |
| `Core/Models/RoutingModelGateway.cs` | **KEEP** | Routes by vendor prefix among registered `INamedModelGateway`s. It is a *transport* dispatch, not a policy decision, and the governed invocation seam sits above it. | — |
| `Core/Models/INamedModelGateway.cs` | **KEEP** | The provider adapter contract. | — |

`ModelSelector`, `ModelStep` and `Planner` are **live**. They are marked SUPERSEDE so W7D rewires
them and deletes them at that point — not now, when nothing replaces them yet.

### 2.3 Governance surfaces — consumed, not duplicated

| Surface | Disposition | How W7C consumes it |
|---|---|---|
| `IAiGovernanceRegister` | **KEEP — consumed** | `RegistryAiGovernanceRegister` projects governance records from `ConfiguredAiRegistry`. One register, one source. |
| `IAiGovernanceEvaluator` | **KEEP — consumed** | Called twice per route: once at request scope, once per candidate. |
| `GovernedProviderInvocation` | **KEEP — not yet wired** | Deliberately uncomposed. W7C selects; invoking is W7D's. |
| `AiGovernancePolicy` | **KEEP — consumed** | The composed policy takes its register from the container. |

W7C adds **no second governance path**. `IAiCapabilityRouter` is a *consumer* of W7B; there is no
code in W7C that decides a governance question for itself.

---

## 3. The three design points where W7C departed from the PowerShell, and why

### 3.1 The eligibility vocabulary matches, which is why ADAPT is justified

`ai-routing/router/RoutingEligibility.ps1` names:

```
MODEL_DISABLED  MODEL_DISALLOWED  PROVIDER_DISABLED  PROVIDER_DISALLOWED
PROVIDER_UNAVAILABLE  CAPABILITY_CODING_MISSING  CAPABILITY_TOOL_USE_MISSING
CAPABILITY_VISION_MISSING  CONTEXT_TOO_SMALL  REASONING_LEVEL_INSUFFICIENT
OUTPUT_LIMIT_TOO_SMALL  PRICE_UNAVAILABLE  LOCALITY_CONFLICT  AUTH_ERROR
PROCESSING_TIER_UNSUPPORTED  STRUCTURED_OUTPUT_MISSING  RELIABILITY_TOO_LOW
```

`AiRoutingRejectionReason` carries these as first-class members — `ContextTooSmall` matching
literally — with the availability, capability, context, reasoning and price gates all present. The
`_fixtures/ROUTING_RECOMMENDATION.md` fixture shows `objective CHEAPEST_RELIABLE` (matching
`AiRoutingObjective.CheapestReliable`) and a `PolicyScore` decomposed into
`cost, success, firstAttemptSuccess, costPerSuccess, latency, reliability` — the shape
`AiRoutingWeights` generalises.

**This is a genuine adaptation, not a reimplementation with a similar name.** The one deliberate
divergence: the PowerShell's `RELIABILITY_TOO_LOW` and `PROCESSING_TIER_UNSUPPORTED` gates have no
W7C counterpart, because both depend on observed history W7C does not have. They belong to W7E, and
they are named in the W7D handoff rather than silently dropped.

### 3.2 Two-pass governance

Request scope first, then per candidate. A request-scope `Block` is **terminal** — no chain is
built. A per-candidate `Block` **excludes that candidate** and the others proceed. A per-candidate
`HumanDecisionRequired` is **terminal for the whole routing**, because escalating to a different
model is not an answer to a question a human was asked.

This is why `UnapprovedProvider_IsNeverSelected_AndNeverEntersTheFallbackChain` and
`RequestScopedRefusal_IsTerminal_EvenThoughAPermittedRouteExists` can both pass on the same router.

### 3.3 The fallback chain is derived, not enumerated

TASK 5 asks for "configurable fallback chains (primary model unavailable → allowed secondary →
allowed tertiary)". W7C stores no chain in configuration. It computes:

```csharp
FallbackChain = ranked.Skip(1).Take(_policy.FallbackDepth).ToArray();
```

`ranked` is a slice of `eligible`, and `eligible` contains only routes that survived every gate
**including a per-candidate governance evaluation**. Therefore a chain **structurally cannot contain
a blocked route** — not because a check forbids it, but because there is no code path that could put
one there. An enumerated chain would need a check, and a check that is not run on some path is the
failure mode TASK 5 exists to prevent.

`FallbackDepth` is the configurable part, and it is a **bound on how far a failover may walk**, not a
permission widening what it may walk onto. `TheFallbackCannotBypassGovernance_EvenWhenDepthsAllowIt`
asserts exactly that with a depth of 10 over a registry containing a disabled and an unapproved
route.

### 3.4 Health is a port, not a registry field

TASK 2 lists "health" among the provider registry's fields. W7C carries health through
`IAiModelHealthSource` and declares it in `AiRegistryConfiguration.Health` — a *declared snapshot*,
not a stored property of the registration. The reason is that health is the one registry input with a
short half-life: a stored field invites the assumption that the registry is current, and the ops lane
replaces this source with observed evidence without the router changing at all.

### 3.5 A dependency the router does not transmit, it does not accept

`AiRoutingContext` **lost** its `ProductId` member in W7C. `AiGovernanceEvaluationRequest` has no
counterpart field, so a product scope accepted at the router and unrepresentable to governance would
be a scope the router **silently dropped** — a request that looks governed and is not. Removing the
field makes that unexpressible. Restoring it is a W7D/W7B conversation about the governance request
shape, not a W7C edit.

---

## 4. TASK 8 — secret references: a cross-half disagreement W7D must resolve

The repository-root `config/` directory is the migrated unit's **data plane**: `AiRoutingFoundation.ps1`
loads `config/ai-routing.json`, `config/providers.json` and `config/models.json`, and nothing else in
the repository reads them. It has been in the tree since `052ee5b DevTools baseline` — it predates the
W6 import and sits outside `ai-routing/`, which is why it is easy to miss when auditing the unit.

`config/providers.json` names these secret references:

```
line  22  DEEPSEEK_API_KEY
line  42  ANTHROPIC_API_KEY
line  62  OPENAI_API_KEY          ← the disagreement
line  82  GEMINI_API_KEY
line 102  OPENROUTER_API_KEY
```

The C# side and the committed `appsettings.json` use **`NEXUS_OPENAI_API_KEY`**.

**The two halves of the repository disagree about the name of the same variable.** The file's own
description field states the correct rule — *"SecretReference holds an env-var NAME only - never a
value"* — so the disagreement is about *which* name, not about whether names belong there. W7C did
not resolve it by editing either side:

- `NEXUS_OPENAI_API_KEY` is the approved reference. Replacing it with the vendor-conventional
  `OPENAI_API_KEY` is explicitly forbidden.
- `config/providers.json` belongs to the dormant unit, which W7C does not modify.

`REQUIRES_HUMAN_SECRET_ROTATION` remains active. No credential value was read, moved, tested,
copied or exposed by this lane, and no provider activation requiring the historical credential was
attempted.

**W7D must treat this as an open finding**, not a settled one: a future lane that reconciles the
PowerShell configuration into the registry must translate the reference names, or it will
reintroduce `OPENAI_API_KEY` and silently resolve to nothing.

---

## 5. TASK 10 — provider-specific smoke test ownership

**Recorded, not implemented by this lane.**

- Provider-specific OpenAI / Anthropic smoke and E2E tests belong under **AI Head**.
- **Platform** retains provider-neutral smoke tests only.
- `Nexus.Platform.Providers.OpenAI` already resides under AI Head at `src/Nexus.Platform.Providers.OpenAI`
  and is referenced by `Nexus.Intelligence.slnx` and by the architecture test project. W7C did **not**
  recreate a provider project under Platform, and no such project exists.
- W7C added one provider-adjacent artefact: `OpenAICatalogOptions` and the rewritten
  `OpenAIModelCatalogSource`, both inside the existing AI Head provider project. Neither is a test
  project and neither moves a boundary.
- The existing `RelocatedProviderBoundaryTests` and `RelocatedSecretBoundaryTests` continue to enforce
  the relocation; W7C did not weaken or duplicate them.

---

## 6. What W7D must consume

W7C exit requires this list to be explicit. In dependency order:

1. **`IAiCapabilityRouter`** — callers request a capability, never a provider or a model. The live
   `ModelSelector` / `ModelStep` / `Planner` path must be rewired to it and then deleted.
2. **`AiRoutingOutcome`** — `Selected`, `FallbackChain`, `Eligible`, `Rejected`, `Governance`,
   `Failure`, `Status`. A failover walks `FallbackChain`; it never re-queries the registry.
3. **`AiRoutingContext`** — the four things a caller must supply that the live pipeline does not yet
   carry: classification, context classifications, execution policy (including the cost ceiling and
   currency), and requested tool ids. **This is the W7C limitation the caller scoped out**, and it is
   the first thing W7D must fix.
4. **`GovernedProviderInvocation`** — composed but deliberately unwired. W7D supplies the
   `INamedModelGateway` behind it.
5. **`AiRegistryConfiguration` / `ConfiguredAiRegistry`** — the authoritative model, provider and
   health registry. W7D adds Agents and Prompts to `RegistryAiGovernanceRegister`, which currently
   resolves those two subjects to nothing by design.
6. **`AiRoleSeedOptions` / `AiRoleSeedParser`** — the role seed is configuration (`Ai:Roles`) now,
   not a code literal. A role names the model it *wants*; whether that model may be used is the
   registry's question.
7. **Open findings:** the `config/providers.json` reference-name disagreement (§4), and the
   `RELIABILITY_TOO_LOW` / `PROCESSING_TIER_UNSUPPORTED` gates deferred to W7E (§3.1).

**W7C stops here. W7D is not started.**
