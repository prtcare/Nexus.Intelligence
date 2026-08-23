# Nexus.Int — the Intelligence

The deciding layer. Given a turn from any product, it decides **what** to do, **where** to
look and **how** to answer: intent classification, context ranking, agent selection, model
selection, prompt assembly, and the policy gate in front of all of it.

Deployed as an HTTP service at `/intelligence/v1`. Consumes `Nexus.Platform.*` packages
in-process from the local NuGet feed.

## Is / is not

**Is:** the decisions. Policy gate, intent, `ContextItem` ranking, agent registry, model
selection under a cost ceiling, prompt assembly, turn traces and explanations.

**Is not:** it never sees a product's schema. Products flatten their own entities into the
canonical `ContextItem { Id, Kind, Body, Trust, OccurredAt, Author, RelevanceHint }` before
Intelligence receives them, and `ScopeRef` is **opaque** here — stored and compared, never
parsed. If this repo ever needs to know what a "Workspace" is, the seam has been broken.

It also does not call model providers directly — that is Platform's job, reached through
`Nexus.Platform.Contracts`.

> **Intelligence decides. Platform executes. Products own the data and the experience.**

## Local development

```powershell
dotnet build Nexus.Int.slnx
dotnet test  Nexus.Int.slnx
dotnet run --project src\Nexus.Intelligence.Api\Nexus.Intelligence.Api.csproj
```

Swagger comes up at `http://localhost:5000/swagger`.

**The model provider key lives here and nowhere else**, under
`Platform:Providers:OpenAI:ApiKey`. A product holding a provider credential is an
architectural violation, not a configuration preference. Use `set-openai-key.ps1` in the
NexusAI repo to set or rotate it — never `dotnet user-secrets set`, which parks the value in
PowerShell history.

`Properties\launchSettings.json` must exist and set `ASPNETCORE_ENVIRONMENT=Development`.
Without it the API defaults to Production and **silently ignores user secrets** — which
presents as a confusing 401 from the provider rather than as a configuration error.

## Documentation

Cross-cutting architecture, conventions and decisions: **`..\NexusAI\docs\`** —
start at `DOCUMENTATION_INDEX.md`. This repo has no `docs\` folder of its own.
