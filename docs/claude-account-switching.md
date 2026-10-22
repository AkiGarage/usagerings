# Claude account switching — acceptance spec (2026-10-22)

## What is switched
UsageRings never changes CLIProxyAPI or any running session. It only *decides* and
writes `~/.local/state/usagerings/claude-account-choice.json`
(`{"order":["b","a"],"selected":"b","reason":"…","decidedAt":…,"expiresAt":…}`, valid 10 min).
`~/.local/bin/claude-ab` reads that file (if fresh and well-formed) to choose which
profile (claude-a / claude-b) to try first; otherwise it keeps its old order a → b.
claude-ab still falls through to the other profile on a real limit error.
The file is written only when the user has mapped both CLIProxy Claude accounts to
profiles A and B in Settings.

## Inputs (per account, each refresh = 60 s)
five-hour left % + reset time, weekly left % + reset time (CLIProxy), and active
log blocks (session / weekly) from ~/.claude-a, ~/.claude-b.

## Definitions
- weekly-limited: weekly left ≤ 0, or an active weekly log block.
- 5h-limited: 5h left ≤ 0, or an active session log block.
- recovering: was 5h-limited at the previous decision and 5h left < 5 % (hysteresis band).
- free: not limited, not recovering. unknown: no quota data at all.

## Rules
1. Preferred = among non-weekly-limited accounts, the one whose weekly reset is earliest.
   Ties (resets within 30 min of each other) or unknown resets keep the previous preferred;
   with no previous, account order (A first). Unknown reset ranks after any known reset.
   A challenger replaces the previous preferred only if its reset is > 30 min earlier.
2. Selected = preferred if free.
3. Else the other account if free (reason: preferred is at 5h / weekly limit).
4. Else a recovering or unknown account (never a limited one while such exists).
5. Else (all limited): the account whose limits clear soonest; state = all limited.
6. When preferred becomes free again (5h ≥ 5 % or its reset time has passed) → back to preferred.

Property: if any account is not limited, the selected account is never limited.

## State diagram
```
            preferred free
   ┌─────────────────────────────┐
   ▼                             │
[PREFERRED] ──pref 5h/weekly──▶ [FALLBACK(other)]
   ▲   │                           │ other also limited
   │   │ all limited               ▼
   │   └─────────────────────▶ [ALL_LIMITED(wait soonest)]
   │                               │ any clears
   └──────── pref free ◀───────────┘ (or → FALLBACK if only other clears)
[NO_DATA] when no account has data → no file written.
```
UI: one Japanese line under Claude, e.g.
「いまはA：週の制限がBより先にリセットされるため（10/24 09:00）」
「いまはB：Aが5時間制限中（14:20に解除→Aに戻します）」
