# Reset refresh verification

This supplements `../UsageRefresh.tla` and `../../FetchCache.tla`; neither existing
model nor its invariants were weakened. The Japanese rules and statechart are in
`../../fetch-cache-statechart.md`. Production changes are confined to the Mac
store. Gemini's separate activity monitor is still excluded from reset fetches.

## Rerun

With Java and a local TLC jar (tested with tla2tools-1.7.4.jar):

```sh
TLA2TOOLS=/absolute/tla2tools.jar JAVA=/absolute/java \
  python3 docs/formal/reset-refresh/check.py .build/reset-proof
swift build && swift test
bash script/lint.sh
git diff --check
```

The checker leaves transcripts and state files in the requested directory. Each
fault config must violate the matching invariant, rather than merely exit with
an error. The normal model explores 218 states / 779 steps. Its scope is one
provider/account deadline stream, two deadlines, and three abstract clock ticks.
`knownAt` represents fetch-start time, so learning a reset after a slow fetch is
included. It does not model parser arithmetic, multiple account identities,
provider response latency, service-level retries, or actual OS timer delivery.
Those account combinations and the 20-second grace are checked by Swift tests.

## Validation in the restricted worktree (2026-11-13)

- Normal reset model and five injected faults: PASS with TLC.
- Existing FetchCache and UsageRefresh models and their fault configs: PASS with TLC.
- Lint and whitespace check: PASS.
- `swift build && swift test`, plus standalone `swift test`: blocked before compilation
  by `sandbox-exec: sandbox_apply: Operation not permitted`. Local-cache SwiftPM
  attempts also failed with generated manifest/output-file-map permission errors.
- As an additional check, Xcode's `swiftc` directly compiled all production Swift
  sources and vendored Zstd into a testing-enabled library, linked the real
  ResetRefreshTests XCTest bundle, and ran it with Xcode's `xctest`: 16 tests,
  zero failures. This is not a pass of the complete SwiftPM quality gate.
  Ignored transcripts are in `.build/manual/`; no installed app was launched.
- In an ignored scratch copy of the production store, changing the one-shot
  guard back to three attempts made the real XCTest run fail in six assertions.
  Reloading the unchanged production library returned all 16 tests to PASS;
  the scratch mutation never touched the reviewed source.
- Formal drift guard: blocked because the historical sync commit f949d06 is not
  available in this shallow checkout. Its sync records were not advanced.

Independent read-only Sol review: three rounds, final APPROVE. S1 (partial
account success, including the parser's aggregate error) and S2 (initial fetch
spanning the reset) are resolved with regressions. No commit, push, PR, release,
or integration was performed. Remaining timing risks are sleeping machines,
OS callback delay, and a provider that has not yet restored its reported quota;
a reset check never synthesizes quota or retries beyond the normal service policy.

## Quality-gate retry (2026-11-13)

The runner built the app successfully but could not import XCTest with standalone
Command Line Tools selected. `CONTRIBUTING.md` now documents selecting full Xcode
with `DEVELOPER_DIR` and its matching `SDKROOT` before `swift build && swift test`.
No test imports, assertions, or package targets were removed to hide this failure.

In the restricted worktree, the exact gate still fails at SwiftPM manifest
sandboxing. Xcode retries with local caches and `--disable-sandbox` also encounter
denied writes to SwiftPM build files. Rebuilding the production library and the
current reset tests directly with `.build/manual/check.py` succeeded again:
16 XCTest cases, zero failures. `bash script/lint.sh` and `git diff --check` pass.
The complete SwiftPM gate still needs an unrestricted runner with full Xcode
selected; the direct XCTest run is not a substitute for that gate.
