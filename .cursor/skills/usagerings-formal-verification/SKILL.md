---
name: usagerings-formal-verification
description: Use before and after any change to how UsageRings reads provider usage (MultiUsageService fetchAll, sourceArguments, the Claude section, retries, CodexBarCLI arguments) or how MultiUsageStore refreshes, merges, retains stale values and handles resets. Checks that only the official provider CLI is ever used, disabled providers are never fetched, and retries stay bounded.
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
- `TLA2TOOLS_JAR=/path/to/tla2tools.jar docs/formal/check.sh` must print PASS for UsageRead (45 distinct states), CodexBarGate and Fault-RetryLogout (caught NoRetryOnLogout).
- `swift test --filter SourcePolicyTests` and `./script/lint.sh` must pass.
- Read every TLC result, pass or fail, with the `/statechart` skill and `docs/formal/view.mjs` as the view. On a pass it draws the chart (`docs/formal/chart.mmd`, 6 states, 10 arrows). On a fail it gives the shortest bug path in plain words.

## Coverage (model ↔ code)
| Model | Code |
|---|---|
| source, OnlyOfficialCli | MultiUsageService.sourceArguments |
| enabled, DisabledNeverFetched, HiddenOnlyWhenDisabled | MultiUsageService.fetchAll provider filter and Claude section omission |
| ClaudeCacheEmpty → pending | MultiUsageService.claudePendingSection |
| CliTimesOutRetry / GiveUp, BoundedRetries | MultiUsageService retry once on timeout or launch failure (RetrySafetyTests) |
| CliFailsRetry, NoRetryOnLogout (ログアウト時は再試行しない) | attempt retries a nonzero exit once unless isLogout or a partial result; Fault-RetryLogout breaks the guard |
| CliOk / CliFails, Shown/FailedOnly… | ProviderSection windows vs failureText |
Sync commit: 280d6ee (adds the nonzero-exit retry and the logout no-retry rule; the extra no-token-accounts attempt is bounded and left to tests). Move it forward only after confirming that the table still describes the code at the new commit.

## Bounds and what is left out
One provider instance, one retry, the cli states ok/missing/signedOut/timeout. Not covered: what the CLI output means (that is parser tests), multi-account Antigravity, the UI drawing, real network timing.

## Real bug or modeling error?
If TLC fails, replay the statechart path against the real code as a SourcePolicyTests or RetrySafetyTests case. If the code really does it, it is a bug: fix the code, not the invariant. If the code cannot do it, the model is wrong: fix the model and update the coverage table. Never weaken an invariant to make it pass.

## When the change is intended
Update the spec, the coverage table and the tests together, rerun all three checks, regenerate the chart with /statechart, and move the sync commit.

## Refresh and display model (UsageRefresh)
Rules in plain Japanese:
1. 別アカウントの数字を表示しない (NoCrossAccount)
2. 古い応答が新しい表示を上書きしない (StaleNeverOverwritesNewer)
3. 取得失敗を 0% や成功として表示しない (FailureNeverShownAsSuccess)
4. リセット前の古い応答が新しい期間の表示を上書きしない (OldPeriodNeverOverwritesNew, RetainedNeverFromPastPeriod)
5. スリープ復帰や更新の重なりでも取得は同時に1本だけ (AtMostOneFetch)
6. 取得中に頼まれた更新は捨てられず、取得が終われば必ず次の取得が始まる (NoLostRefreshRequest)
7. 停止より前に始まった取得の結果は、停止後の表示に反映されない (NoApplyAfterStop)

Run: `docs/formal/check-refresh.sh`. It must print PASS for UsageRefresh and PASS ... caught for every Fault-*.cfg. Each fault config turns off one real guard and TLC must report the matching violation; if a fault is not caught, the invariant is too weak.

| Model | Code |
|---|---|
| Start with SingleFlight | MultiUsageStore.refresh guard !isRefreshing |
| Complete, NewDisp ok | MultiUsageStore.apply merge of the fetched sections |
| Retained, RemapById | retainingStaleValues remaps old windows by account id |
| DropStaleAtReset, ExpireStale | isRetainable resetAt >= now, scheduleExpiry |
| FailIsFailure | non-transient errors keep failureText with empty windows |
| Reset, Sleep, Wake, Reorder | ResetRefreshPlanner, wake and clock-change replans, account order changes |
| Request, queued, runQueued | refresh() during a fetch queues one full refresh; apply() starts it (Fault-DropQueuedRefresh) |
| Stop, Restart, gen, GenGuard | stop() bumps the generation; an older fetch is not applied (Fault-ApplyAfterStop) |
Bounds: 2 accounts, 4 requests, 2 periods, 2 stops (63808 distinct states). Not covered: 5h observedAt age, Gemini monitor merge, retry offsets.
Real views: verify-usagerings. Drift guard: `.formal/guard.json` with formal_guard.py; UsageRefresh sync commit 280d6ee (providerError counts as transient, i.e. the model's "transient" outcome).

## OpenDesign and fitted vertical tab

OpenDesign is a separate read-only control API path, not a CodexBarCLI provider.
Existing UsageRead/UsageRefresh invariants remain unchanged: the old CLI source
policy still covers Antigravity/Grok/Claude, and refresh/stale merging is unchanged.
The ten-provider source-policy test now enumerates 1,024 disabled subsets.

Run `docs/formal/opendesign/check.sh /abs/new/evidence-directory`. It checks
OpenDesignRead and VerticalTabFit, then requires each of six injected faults to
violate its named invariant. Read the models with `/statechart`, using
`read-view.mjs` / `fit-view.mjs` in that directory. No existing invariant is weakened.

Rules in plain Japanese are written immediately above each invariant in the specs:
- 無効にしたOpenDesignの認証情報を読まず、通信もしない。
- 検証に失敗した応答を残量として表示しない。
- 403を再ログインが必要な状態として扱わない。
- 画面に合わせて縮小しても、保存した拡大率を変えない。
- 縦表示は、その画面に収まる拡大率で描画する。
- 大きい画面や横表示では、利用者が選んだ拡大率に戻る。

| Model | Code / executable proof |
|---|---|
| Start, DisabledNoIO | MultiUsageService.fetchOpenDesignUnlessDisabled; OpenDesignUsageTests disabled case |
| Credential / Directory / Funding | OpenDesignUsageClient.fetch: local key then two sequential GETs |
| OnlyValidatedQuota | OpenDesignUsageParser.funding, openDesignSection; malformed response tests |
| ForbiddenIsNotLogout | OpenDesignUsageClient.outcome; 401/403 test |
| ChangeScreenOrOrientation, SavedZoomUnchanged, FitsScreen, RestoresZoom | AppDelegate.refreshTabScreenGeometry → EdgeTabPresentationState.maxCollapsedLength → MultiEdgeTabView.updateCollapsedSize; VerticalTabFitTests native view screen-transition test |
| Fit | MultiCollapsedUsageView.fittedBarZoom and RingDetailCardController.context; fit boundary and hit-target tests |

Bounds: one fetch (no retry), response classes 200/401/403/500, credential and
payload validity; three abstract zoom levels, two screen sizes, two orientations.
The fit model describes the settled view after SwiftUI processes a screen change,
not intermediate notification delivery. Its short screen fits the minimum zoom;
screens too short even for 0.6, fractional sizing, JSON arithmetic and pixels are
left to Swift tests / real view exports. The app retains the minimum 0.6 in that
unsupported geometry. Existing source-policy and refresh models were compared
against 280d6ee: this change adds a provider without altering those algorithms.
Sync commit: 4c8b674d4e0fdd8aac402b1481ad8405b019b16c (moved from f949d06 on 2026-11-14 after reading the diff: MultiUsageService only passes a Codex CODEX_HOME override to the same CodexBarCLI call, MultiCollapsedUsageView only names the 0.5 exhaustion threshold, RingDetailCard adds Claude ticket lines and per-window lock greying; none changes source choice, provider filter, retries, OpenDesign fetch or zoom fitting, so the models are unchanged and TLC passes all specs and fault configs; records in `.formal/guard.json`).

After TLC passes, follow `verify-usagerings` for isolated real views. For real
OpenDesign data on a logged-in Mac, use its explicit opt-in XCTest command.
