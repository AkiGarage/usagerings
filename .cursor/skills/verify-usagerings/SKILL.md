---
name: verify-usagerings
description: Use after any change to UsageRings panels, rings, refresh, stale or failure display, before saying it works. Builds a separate debug binary and renders the real SwiftUI views in demo mode (own defaults suite com.akigarage.usagerings.demo, no menu bar app, no provider CLI calls) to PNG files, then you look at them. Never run script/build_and_run.sh for this; it kills the installed UsageRings.
---

# Verify UsageRings in the real views

## Isolation
- Debug binary from `swift build` in this worktree, not the installed app in ~/Applications.
- `--demo-export <abs dir>` uses demo data and the separate defaults suite, renders, prints files and exits. It never starts NSApplication, never reads provider CLIs, never touches the running app.
- Never use `script/build_and_run.sh` or `pkill` here.

## Run
`.cursor/skills/verify-usagerings/verify.sh [/abs/new/dir]` must print ok for every file and the evidence path. Then open the PNGs and check by eye.
Over non-interactive SSH to a Mac (e.g. the mini), export `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Command Line Tools have no XCTest) and `GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=` (the keychain helper fails without a GUI session when SwiftPM fetches Sparkle) before `swift build`/`swift test`.

## Feature map
| Feature | Evidence file | What to see |
|---|---|---|
| Normal panel | panel-dark.png, panel-light.png | every provider with rings, remaining %, reset times |
| Fetch failure is never 0% or success | panel-failure-no-data.png | Grok shows "–" and the red failure text, no number, no green bar |
| Rings bar | rings-horizontal.png, rings-vertical.png | one ring per account, account names match their own numbers |
| Warning colors | rings-warning-critical.png | low remaining shown in warning or critical color |
| Hover cards | hover-*.png | the card belongs to the ring named in the file |

## Link to the formal checks
The rules come from `docs/formal/UsageRefresh.tla` (see usagerings-formal-verification). TLC proves the ordering rules; this skill proves the real views show the results the right way. Stale display and reset timing are not rendered by demo export; they are covered by StaleRetentionTests and ResetRefreshTests.
