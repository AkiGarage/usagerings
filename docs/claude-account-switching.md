# Claude account switching — acceptance spec (2026-10-22)

## What is switched
UsageRings never changes CLIProxyAPI or any running session. It only *decides* and
writes `~/.local/state/usagerings/claude-account-choice.json`
(`{"order":["b","a"],"selected":"b","reason":"…","decidedAt":…,"expiresAt":…}`, valid 10 min).
`~/.local/bin/claude-ab` reads that file (if fresh and well-formed) to choose which
profile (claude-a / claude-b) to try first; otherwise it keeps its old order a → b.
claude-ab still falls through to the other profile on a real limit error.
The file is written only when (1) Settings「Claudeの使う順番を自動で決める」is on
(default on) and (2) both CLIProxy Claude accounts are mapped to profiles a/b. Mapping is
automatic: the masked e-mail in ~/.claude-a/.claude.json and ~/.claude-b/.claude.json
(oauthAccount.emailAddress only) must each match exactly one CLIProxy account; any
ambiguity → no mapping → no file (claude-ab keeps a → b).

## Provider visibility
Each provider has an on/off toggle (persisted). Explicit off → never fetched.
No choice yet → probed at most every 30 min and turned on automatically (and remembered)
the first time it reports configured usage; never turned off automatically.

## Inputs (per account, each refresh = 60 s)
five-hour left % + reset time, weekly left % + reset time (CLIProxy, per account).
Log blocks are not used for the choice (log slot A mixes ~/.claude and ~/.claude-a, identity unverified).
When the hint must not apply (setting off, unmapped, Claude hidden, no data) the file is
overwritten with an expired hint (expiresAt 0), never deleted.

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
6. When preferred becomes free again (5h ≥ 5 % or its 5h reset time has passed) → back to preferred.
7. All-limited ranking: per active cause only (5h / weekly); a cause with no known future clear time counts as "unknown" and ranks last.
8. Accounts are evaluated in profile order (a, b) regardless of CLIProxy listing order.

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
