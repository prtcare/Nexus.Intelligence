# AGENTS.md — Nexus.Intelligence

**Repository**: github.com/prtcare/Nexus.Intelligence · solution Nexus.Intelligence.slnx. The local clone root is wherever the repository was cloned — it is not a property of this repository, so no absolute path is recorded here.
**Is**: The deciding layer — intent, context ranking, agent selection, model selection, prompt assembly, policy gate. Deployed at `/intelligence/v1`. Consumes `Nexus.Platform.*` packages via this repository's own `nuget.config`. See README.md for the full is/is-not.
**This repo has no `docs\` folder of its own.** All cross-cutting documentation lives in the sibling repository, `..\Nexus.Platform\docs\`.

## Read before implementing (always)

1. This file.
2. `..\Nexus.Platform\docs\DOCUMENTATION_INDEX.md`
3. `..\Nexus.Platform\docs\CURRENT_STATE.md`
4. `README.md` (this repository) — is/is-not, local dev commands, the provider-key rule.
5. Whatever the active implementation prompt names as task-specific reading.

If `..\Nexus.Platform` is not present as a sibling folder, stop and report.

## Authoritative rules for this repository

Repository instructions in this file override a coding model's default conventions. Coding/naming/security/testing/git rules live in and are owned by the standards indexed in `..\Nexus.Platform\docs\DOCUMENTATION_INDEX.md`. The full model-independent development process is `..\Nexus.Platform\docs\AI_DEVELOPMENT_GOVERNANCE.md`.

## The one rule specific to this repository

This service never sees a product's schema and never parses `ScopeRef` — it is stored and compared, opaque. `Nexus.Intelligence.Contracts` must expose no vendor SDK type and no provider implementation: it is the only `Nexus.Intelligence.*` artifact a Product may reference, so a vendor type here becomes a vendor type in a Product. The provider adapter itself is a sibling project (`src\Nexus.Platform.Providers.OpenAI`) that implementation assemblies — not Products — reference. If a change requires either Product to see a schema, or `Contracts` to carry a vendor type, stop and report.

## Before changing anything

Inspect existing implementation and naming before adding anything new. Confirm `git status` is clean and `git fsck` reports no corruption before starting — a `.git-broken\` folder still sits here pending `M-08-2.1`; do not delete it without architect approval.

## What you may decide yourself / what requires architect approval / before declaring completion

Same boundary as `..\Nexus.Platform\docs\AI_DEVELOPMENT_GOVERNANCE.md` defines. When in doubt, stop and report rather than guess.

## Known temporary mechanisms in this repository

See `..\Nexus.Platform\docs\CURRENT_STATE.md`. As of 2026-08-25: this repository's `nuget.config` sources only `nuget.org` and `github-prtcare` (GitHub Packages, `nuget.pkg.github.com/prtcare`); the former `C:\Personal\LocalNuGet` source was removed as part of M-08-1.1. `InMemoryMemoryStore` is genuinely in-memory here (`ConcurrentDictionary`, no persistence).

`ISecretResolver` is **built**, not pending: the contract is `Nexus.Platform.Contracts.Secrets.ISecretResolver` and `AddNexusPlatform` binds it to `Nexus.Platform.Core.Secrets.EnvironmentSecretResolver`, whose reference namespace is the process environment. This service therefore reads `Platform:Providers:OpenAI:ApiKeyRef` as an **environment variable name** and never holds a credential value. `set-openai-key.ps1` is **RETIRED (2026-09-13)** — an owner decision; provider credential configuration belongs to AI Head, and the script is not a supported operator mechanism in any repository, here or in Platform. See `README.md` for why following it here yielded a 401 rather than a configuration error. The Platform smoke host's separate `StoreSecretResolver` is unchanged and is not a mechanism this service shares.
