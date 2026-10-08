# MODEL AUTHORITY — the two model surfaces

**These are two different things. They are never interchangeable, and neither is ever called "the model
catalogue".** W10.7A measured that using one phrase for both is what allowed a role to resolve to a model
the router must then refuse.

---

## The two surfaces

### Provider Model Catalogue

| | |
|---|---|
| Configuration | `Platform:Providers:OpenAI:Catalog:Models` |
| Port | `IModelCatalog` |
| Reached through | `OpenAICatalogOptions` → `OpenAIModelCatalogSource` → `AggregatingModelCatalog` |
| Answers | **"can the provider implementation serve this model?"** |
| Presence means | **`PROVIDER_SUPPORTED`** |
| Authority | **provider capability and support only** |

It is **provider-local capability metadata**. It describes what an implementation knows how to call.

### Governed AI Model Registry

| | |
|---|---|
| Configuration | `Ai:Registry:Models` |
| Port | `IAiModelRegistry` |
| Reached through | `ConfiguredAiRegistry` |
| Answers | **"may Nexus route to this model?"** |
| Presence means | **`NEXUS_ROUTABLE`** |
| Authority | **routability, governed model identity, routing participation, selection, pricing association** |

It is the **governed set Nexus is permitted to route to**. It is the authority that decides whether a
model may be used at all.

## The rule, in one line

```
provider-supported  !=  Nexus-routable
```

**A model absent from the registry must not become routable merely because a provider implementation
supports it.** Adding provider support does not alter governed routing, and removing a model from the
registry immediately removes its routing eligibility with no change to any provider data.

## The live example: `openai:gpt-4o`

```
Provider Model Catalogue   present
Governed AI Model Registry ABSENT
```

This is deliberate and preserved. It is classified **`PROVIDER_SUPPORTED_NOT_REGISTERED_FOR_ROUTING`**.

It is **not** added to the registry during W10.7A, and it is **not** deleted from the catalogue merely
to make the two surfaces agree. Registering it is a separate, later, governed configuration decision.

## Where this is enforced

`AiRoleResolver` — the only place that consumes both — consults them **in order of authority**:

1. **the catalogue**, as a capability constraint: does any supported model match the assignment and
   declare the required capabilities?
2. **the registry**, as the authorization: is that model a member of the governed set?

A model that passes (1) and fails (2) resolves to `null` with a decision trace reading
`PROVIDER_SUPPORTED_NOT_REGISTERED_FOR_ROUTING`. **`AiRoleResolver` output is a subset of the governed
registry's routable models**, and the invariants are asserted in
`tests/Nexus.Intelligence.Tests/Registry/ModelAuthorityInvariantTests.cs`.

## Why the ordering is catalogue-first

Both surfaces must admit a model. Catalogue-first means a model the provider cannot serve is refused
for the right reason — *"no provider implementation"* — rather than being reported as a governance
refusal it is not. Registry-second means provider support never stands in for authorization.

## Pricing is not authorization

A registration in the registry carries pricing metadata (`InputCostPer1kTokens`,
`OutputCostPer1kTokens`, `CostCurrency`). **Pricing is an association on a membership; it is not a
membership.** A model with prices and no registry entry is unroutable, and pricing presence must never
be read as permission to route.

## Do not normalise these away

Do not silently unify the two id sets, rename one to match the other, or generate one from the other.
The difference between them is a governance decision expressed in configuration, and a tool that
"fixes" it destroys the record of which models Nexus has actually authorized.
