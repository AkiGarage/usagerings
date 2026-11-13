# Refresh budget and partial merge verification

2026-11-13: the previous UsageRefresh model passed 63,808 states but described
only full refreshes. That was verification drift, not an observed product defect.
No existing invariant or full-check bound has been removed or weakened.

## Rules and code coverage

| Rule (Japanese) / model | Production code / executable regression |
|---|---|
| 自動取得は間隔とエラー待機を守る。`AutomaticRespectsBudget` | `ProviderRefreshBudget.deferred`; `MultiUsageStore.refresh` subtracts deferred providers; interval and backoff tests |
| 手動更新とリセット更新は予算を迂回する。`ExplicitBypassesBudget` | `Reason`, `deferred`; user/targeted-reset test |
| 失敗で待機を2・4・8倍にし、成功で戻す。`BackoffMatchesOutcome` | `record`; failures, partial-account failure, cap and success tests |
| キュー内の手動更新理由を自動更新で失わない。`QueuedUserSurvives` | `queuedRefreshReason`, `refreshIfQueued`; queued-user store regression and ProviderBudget Start/Request/Complete |
| 未取得の未失効値の観測と成否を変えない。`DeferredValuesUnchanged` | `apply(partial:)` preserves untouched sections and Codex snapshot; interval test compares the entire window and observedAt |
| 未取得値もリセット後は失効する。`DeferredValuesExpire` | partial merge prunes budgeted windows; reset, expiry timer and five-hour tests |
| 別アカウント・古い取得・失敗・旧期間の値を成功として表示しない。Existing UsageRefresh invariants | `retainingStaleValues`, account-id remapping and expiry; existing stale/reset tests |
| 同時取得・更新要求の消失・停止後の適用を許さない。Existing UsageRefresh invariants | `isRefreshing`, `queuedFullRefresh`, `stopGeneration`; existing refresh tests |

`UsageRefresh.tla` now puts the selected targets in each in-flight request and
merges fetched accounts only. Account subsets overapproximate provider groups:
real admission selects all accounts of a provider together, while the model also
allows independently selected accounts and empty selections. The existing
account-order permutation remains, so account remapping is still checked.
Untouched expired observations are cleared, and untouched success/failure state
is preserved. Queued requests may also select a subset on the next admission.
Bounds remain two accounts, four requests, two periods and two stops.

`ProviderBudget.tla` separately checks the deterministic admission arithmetic,
completion-time accounting, and user/automatic reason coalescing. One time unit
is the configured interval, not a claim about a provider's service limits.
One budgeted provider, four checks and eight ticks cover all three backoff
levels, the cap, a subsequent success, and both override reasons. CLI failures
include partial account failures; raw error classification is tested in Swift.
The other providers do not participate in this admission policy unless configured;
the real store tests assert that cheap providers still fetch on the minute tick.

The composition boundary is the target mask: ProviderBudget chooses it at start,
UsageRefresh freezes it until completion. Generation rejection is checked by
UsageRefresh; discarded generations never reach `record` in the store.
A targeted reset during an active request is replanned by ResetRefreshPlanner,
not put into the full-refresh reason queue.

Not modeled: absolute seconds, arbitrary preference arithmetic, wall-clock jumps,
five-hour observedAt age, Gemini monitor merging, reset retry offsets, cloud
publication, or pixels. Swift tests cover time boundaries, age and configuration.
The FetchCache model is unchanged: deferral stutters observations while expiry
continues (see `../fetch-cache-statechart.md`).

## Commands

Set `JAVA` to a Java 11+ executable and `TLA2TOOLS_JAR` to an installed tla2tools jar.
Run `bash docs/formal/check-refresh.sh /absolute/new/evidence-directory`.
The full checks must pass and each fault must violate its named invariant.
The evidence directory is retained; the script does not delete files.

New mutation witnesses (shortest paths reported by TLC):

- `Fault-ReplaceDeferred`: start with an empty target mask → completion replaces
  an untouched observation. `DeferredValuesUnchanged` catches it.
- `Fault-KeepDeferredAcrossReset`: start → queue a full refresh → successful
  completion starts a follow-up without that provider → reset → the follow-up
  completion keeps its old-period value. `DeferredValuesExpire` catches it.
- `BudgetFault-Interval`: start → queue an automatic request → completion starts
  the queued request before the newly recorded deadline.
- `BudgetFault-Override`: start → queue a user request → completion starts the
  queued user request but wrongly defers its provider inside the interval.
- `BudgetFault-Backoff`: failed check → records one interval instead of two.
- `BudgetFault-UserReason`: running check → user refresh gets recorded as automatic.

The existing seven UsageRefresh fault configurations remain required.
The final full checks reached 428,720 UsageRefresh states and 33,041 ProviderBudget
states; both passed. All thirteen refresh/budget mutations were caught. The chart
projections reached 28 and 35 states, respectively.
These are deliberate model mutations, not findings in the production code.

## Charts

`refresh-chart.mmd` and `budget-chart.mmd` are generated from the models with the
statechart skill, using `refresh-view.mjs` / `budget-view.mjs`. The `*Chart.cfg`
files are explicitly constrained diagram projections; they never replace the
unconstrained full verification configs. The refresh chart shows one request,
one period and no stop/sleep/reorder/queued state. The budget chart shows one
check and one tick. Thus the charts omit multi-request interleavings and backoff
progression; the full checks and fault traces prove those cases.

Regenerate with the statechart skill command, `TLA2TOOLS=$TLA2TOOLS_JAR`,
`docs/formal/UsageRefresh.tla --config docs/formal/UsageRefreshChart.cfg --view docs/formal/refresh-view.mjs --out /absolute/new/refresh-chart`,
and similarly `ProviderBudget.tla`, `ProviderBudgetChart.cfg`, `budget-view.mjs`.
Copy each resulting `chart.mmd` to its named checked-in chart.

## Sync metadata and governance

`python3 -B script/formal_guard.py .` checks all registered model/source/config
fingerprints in `.formal/guard.json`, including uncommitted verified content.
It also compares invariant bodies, invariant lists, constants and source/config
mappings against HEAD. Removing a rule, reducing a bound or dropping a mapped
source fails even if a fingerprint is updated. Run
`python3 -B Tests/FormalGuardTests.py` for the eight mutation regressions.

The old machine-local formal_guard.py cannot verify this shallow, uncommitted
worktree: its historical sync commit is absent, and any dirty source is STALE.
It remains unchanged. The repository-local guard uses explicit verified content
hashes so that the runner can commit the exact verified change without needing
a commit during verification. `sync_commit` records the reviewed base revision;
`sync_sha256` records the reviewed contents, including the new budget source.
Re-run the model and tests before updating these fingerprints. Other models have
unchanged specs/sources at the reviewed base; their checks are re-run as well.
The historical approval marker is unchanged; no new approval is claimed.
