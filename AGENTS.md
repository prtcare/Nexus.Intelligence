# AGENTS.md — Nexus.Int (Nexus.Intelligence)

**Repository**: C:\Personal\Nexus.Int · github.com/prtcare/Nexus-Int · solution Nexus.Int.slnx
**Is**: The deciding layer — intent, context ranking, agent selection, model selection, prompt assembly, policy gate. Deployed at `/intelligence/v1`. Consumes `Nexus.Platform.*` packages via this repository's own `nuget.config`. See README.md for the full is/is-not.
**This repo has no `docs\` folder of its own.** All cross-cutting documentation lives in the sibling repository, `..\NexusAI\docs\`.

## Read before implementing (always)

1. This file.
2. `..\NexusAI\docs\DOCUMENTATION_INDEX.md`
3. `..\NexusAI\docs\CURRENT_STATE.md`
4. `README.md` (this repository) — is/is-not, local dev commands, the provider-key rule.
5. Whatever the active implementation prompt names as task-specific reading.

If `..\NexusAI` is not present as a sibling folder, stop and report.

## Authoritative rules for this repository

Repository instructions in this file override a coding model's default conventions. Coding/naming/security/testing/git rules live in and are owned by the standards indexed in `..\NexusAI\docs\DOCUMENTATION_INDEX.md`. The full model-independent development process is `..\NexusAI\docs\AI_DEVELOPMENT_GOVERNANCE.md`.

## The one rule specific to this repository

This service never sees a product's schema and never parses `ScopeRef` — it is stored and compared, opaque. It never calls a model provider directly (that is `Nexus.Platform.Contracts`' job). If a change requires either, stop and report.

## Before changing anything

Inspect existing implementation and naming before adding anything new. Confirm `git status` is clean and `git fsck` reports no corruption before starting — a `.git-broken\` folder still sits here pending `M-08-2.1`; do not delete it without architect approval.

## What you may decide yourself / what requires architect approval / before declaring completion

Same boundary as `..\NexusAI\docs\AI_DEVELOPMENT_GOVERNANCE.md` defines. When in doubt, stop and report rather than guess.

## Known temporary mechanisms in this repository

See `..\NexusAI\docs\CURRENT_STATE.md`. As of 2026-08-23: this repository's own `nuget.config` is what actually references `C:\Personal\LocalNuGet` (NexusAI has none); `InMemoryMemoryStore` is genuinely in-memory here (`ConcurrentDictionary`, no persistence); `set-openai-key.ps1` in NexusAI is documented as standing in for the not-yet-built `ISecretResolver`.
