# Nexus.Intelligence — the Intelligence

The deciding layer. Given a turn from any product, it decides **what** to do, **where** to
look and **how** to answer: intent classification, context ranking, agent selection, model
selection, prompt assembly, and the policy gate in front of all of it.

Deployed as an HTTP service at `/intelligence/v1`. Consumes the neutral `Nexus.Platform.*`
packages (`Nexus.Platform.Contracts`, `Nexus.Platform.Core`, `Nexus.Platform.Identity`,
`Nexus.Platform.Persistence`) from GitHub Packages, pinned to exact immutable versions in
`src\Nexus.Intelligence.Api\Nexus.Intelligence.Api.csproj`. Feed configuration is
`nuget.config` in this repository root.

## Is / is not

**Is:** the decisions. Policy gate, intent, `ContextItem` ranking, agent registry, model
selection under a cost ceiling, prompt assembly, turn traces and explanations.

**Is not:** it never sees a product's schema. Products flatten their own entities into the
canonical `ContextItem { Id, Kind, Body, Trust, OccurredAt, Author, RelevanceHint }` before
Intelligence receives them, and `ScopeRef` is **opaque** here — stored and compared, never
parsed. If this repo ever needs to know what a "Workspace" is, the seam has been broken.

Within this repository, the provider adapter is a **sibling project** —
`src\Nexus.Platform.Providers.OpenAI` — reached by `Nexus.Intelligence.Api` as a
`ProjectReference`. Under V3 the AI Head owns provider routing, model selection, provider
adapters and failover; Platform no longer does. The boundary that still holds, and the one
that matters to a Product, is the one below it: `Nexus.Intelligence.Contracts` is the only
`Nexus.Intelligence.*` artifact a Product may reference, so it must expose no vendor type and
no provider implementation. Products reach the AI Head over HTTP or through the neutral
capability contracts, never by taking a provider dependency of their own.

> **Intelligence decides. Platform executes. Products own the data and the experience.**

## Local development

```powershell
dotnet build Nexus.Intelligence.slnx
dotnet test  Nexus.Intelligence.slnx
dotnet run --project src\Nexus.Intelligence.Api\Nexus.Intelligence.Api.csproj
```

Swagger comes up at `http://localhost:5000/swagger`.

### The provider credential is a reference, never a value

This service binds **`Platform:Providers:OpenAI:ApiKeyRef`** and reads no other provider key.
Its value is a **reference name — not the credential**. `Nexus.Intelligence.Api` resolves that
name through `ISecretResolver` (`Nexus.Platform.Contracts.Secrets`), which `AddNexusPlatform`
binds to `EnvironmentSecretResolver` (`Nexus.Platform.Core`). That implementation's reference
namespace is **the process environment**, so the reference *is* an environment variable name
and the credential value lives there:

```powershell
$env:NEXUS_OPENAI_API_KEY = "<the credential>"   # the value: environment, never config
```

with the reference the service reads committed in `appsettings.json`:

```json
{ "Platform": { "Providers": { "OpenAI": { "ApiKeyRef": "NEXUS_OPENAI_API_KEY" } } } }
```

The name is upper-snake per `CONFIGURATION_STANDARDS.md` §14. The reference is committed
because it is not a secret; the **value never is**, in any file, in any environment.

**`set-openai-key.ps1` is RETIRED (2026-09-13) and is not this service's mechanism — nor
anyone's.** It wrote a raw value to `Platform:Providers:OpenAI:ApiKey` — a key this service does
not bind — and it wrote it to the user-secrets store, which `EnvironmentSecretResolver` does not
open. Running it and expecting this API to pick the credential up produced a provider **401**, not
a configuration error, because nothing in the resolution path ever reads that key. By owner
decision the script is no longer a supported operator mechanism in any repository: provider
credential configuration belongs to AI Head, here, through the reference above. Do not document it
as a path and do not build a Platform-side replacement.

The Platform smoke host (`samples\Nexus.Platform.SmokeHost`) keeps its own
`StoreSecretResolver` unchanged — that adapter is credential-adjacent, which is why it lives in a
sample host and not in neutral CORE. It is not a mechanism this service shares, and it is no longer
documented as being populated by the retired script.

A product holding a provider credential is an architectural violation, not a configuration
preference. See `W7A1` in the audit tree for the recorded defect and its disposition.

`Properties\launchSettings.json` must exist and set `ASPNETCORE_ENVIRONMENT=Development`.
Without it the API defaults to Production and **silently ignores user secrets**.

This does **not** affect the provider credential — that resolves from the environment under the
reference above, in every environment, Development included. What it does affect is anything
else a developer parks in the user-secrets store, which then appears to be set and is not.

## Documentation

Cross-cutting architecture, conventions and decisions: **`..\Nexus.Platform\docs\`** —
start at `DOCUMENTATION_INDEX.md`. This repo has no `docs\` folder of its own.
