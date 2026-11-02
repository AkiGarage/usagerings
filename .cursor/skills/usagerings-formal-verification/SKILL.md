---
name: usagerings-formal-verification
description: Use before and after any change to how UsageRings reads provider usage (MultiUsageService fetchAll, sourceArguments, the Claude section, retries, CodexBarCLI arguments). Checks that only the official provider CLI is ever used, disabled providers are never fetched, and retries stay bounded.
---

# UsageRings usage-reading verification

## Promise
UsageRings reads Antigravity, Grok and Claude only through `CodexBarCLI usage --provider X --source cli`, never touches a disabled provider, and never retries forever.
Harm if broken: cookie/web/OAuth reads that break provider terms, hidden network calls for providers the user turned off, or a hung panel.

## Two checks, and why
1. TLA+ model `docs/formal/UsageRead.tla` with TLC: bad orderings of refresh, CLI failure, timeout, retry and user toggles. TLA+ was chosen because the risk is about step order and state, not arithmetic.
2. `Tests/CodexUsageWidgetTests/SourcePolicyTests.swift` on the real code: all 512 disabled-provider subsets, the exact CLI arguments of each provider. Swift has no practical verifier for this, so the real function is tested exhaustively over its whole finite input space.
Plus `script/lint.sh`, which bans proxy, cookie, web and Keychain reads in the sources.

## Run (one command each)
- `TLA2TOOLS_JAR=/path/to/tla2tools.jar docs/formal/check.sh` must print "No error has been found" (44 distinct states, depth 4).
- `swift test --filter SourcePolicyTests` and `./script/lint.sh` must pass.
- Read every TLC result, pass or fail, with the `/statechart` skill and `docs/formal/view.mjs` as the view. On a pass it draws the chart (`docs/formal/chart.mmd`, 6 states, 10 arrows). On a fail it gives the shortest bug path in plain words.

## Coverage (model ↔ code)
| Model | Code |
|---|---|
| source, OnlyOfficialCli | MultiUsageService.sourceArguments |
| enabled, DisabledNeverFetched, HiddenOnlyWhenDisabled | MultiUsageService.fetchAll provider filter and Claude section omission |
| ClaudeCacheEmpty → pending | MultiUsageService.claudePendingSection |
| CliTimesOutRetry / GiveUp, BoundedRetries | MultiUsageService retry once on launch failure (RetrySafetyTests) |
| CliOk / CliFails, Shown/FailedOnly… | ProviderSection windows vs failureText |
Sync commit: db3cf06. Move it forward only after confirming that the table still describes the code at the new commit.

## Bounds and what is left out
One provider instance, one retry, the cli states ok/missing/signedOut/timeout. Not covered: what the CLI output means (that is parser tests), multi-account Antigravity, the UI drawing, real network timing.

## Real bug or modeling error?
If TLC fails, replay the statechart path against the real code as a SourcePolicyTests or RetrySafetyTests case. If the code really does it, it is a bug: fix the code, not the invariant. If the code cannot do it, the model is wrong: fix the model and update the coverage table. Never weaken an invariant to make it pass.

## When the change is intended
Update the spec, the coverage table and the tests together, rerun all three checks, regenerate the chart with /statechart, and move the sync commit.
