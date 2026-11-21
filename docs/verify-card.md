# Hover detail card — scripted real-app check

`script/verify_card.py` proves the real app's hover detail card opens and shows
the expected text. It is written as the `command` of an `aki.coding.plan/1`
check (kind `interaction`): it prints exactly one `aki.coding.check/1` JSON
object on stdout, exits 0 only on `PASS`, and logs progress to stderr.

```sh
python3 -B script/verify_card.py \
  --check-id ID --consumer ROUTE --ring 0 \
  --expect 'Codex A の詳細' --expect '1,284 credits' \
  --artifact-dir build/qa/ID
```

## Use in a coding plan

1. Freeze the plan (`aki-mode plan`) before editing. Its `interaction` check runs this
   script; `artifacts` is `build/qa/<ID>/ax.json`; `dependencies` list the changed
   sources and `script/verify_card.py`.
2. After the change, run the script directly once. It builds and writes `ax.json`.
3. Run `aki-mode check --check <ID>`. It re-proves the card live against that
   evidence; the closeout's file-size limit usually stops `swift build` there, and
   the script then drives the binary only if the sources and the binary's sha256 still match `ax.json`.
4. After any further source edit, remove `build/qa/<ID>` and repeat 2–3.

## What it does

1. `swift build --product CodexUsageWidget`.
2. Launches the demo binary `.build/debug/CodexUsageWidget --usagerings-demo
   --demo-hover-ring N` in its own process group. Demo mode reads its isolated
   preferences suite (`com.akigarage.usagerings.demo`,
   `Sources/CodexUsageWidget/App/DemoMode.swift`) and the stable fictional
   fixture (`UsageRingsDemoFixture.swift`); the installed app under
   `/Users/ay/Applications/UsageRings.app` is never launched, read, or killed.
3. Waits up to 60 s for the card (the first launch after a rebuild can exceed 30 s): the card lives in an `NSPanel` at
   `NSWindow.Level.statusBar` (CG layer 25), which `cua-driver list_windows`
   (layer-0 only) never reports, so the script enumerates the process's
   windows via CoreGraphics `CGWindowListCopyWindowInfo` (ctypes, stdlib) and
   reads each window's accessibility tree through the `cua-driver` CLI
   (`get_window_state`, read-only; no input to any app). The card is
   identified by the `の詳細` marker: the title is always `<ring name> の詳細`
   (`RingDetailCardModel.make`), and no other window of the app contains it.
4. Writes evidence into `--artifact-dir` (repo-relative, under the gitignored
   `build/`): `ax.json` (pid, argv, ring, card window id, visible AX texts,
   raw tree markdown, per-expect results) and `card.png` when the window
   capture succeeds. `ax.json` is the contract artifact listed in the closeout
   plan; `card.png` is auxiliary evidence outside the contract hashes. An
   existing `ax.json` is never rewritten: the run still re-proves the card
   live and reports the retained artifact's exact bytes, so a check rerun is
   a fresh consumer proof that leaves the frozen evidence untouched.
5. Terminates only the process group it started (SIGTERM, then SIGKILL,
   reaping the leader before declaring the group empty — an unreaped zombie
   keeps the group alive and makes `killpg` answer EPERM), verifies it is
   gone, and reports `cleanup` accordingly.

## Result contract

`{"schema":"aki.coding.check/1","check_id","consumer","status",
"assertions":{"expected-text","real-binary"},"actions":{"open-card"},
"observed_artifacts":{"build/qa/ID/ax.json":"<sha256>"},"unresolved":[],
"cleanup"}`

- `open-card`: the `の詳細` card window appeared for the launched process.
- `expected-text`: every `--expect` is a substring of the card's visible AX
  texts (one FAIL makes the whole status FAIL with the misses in `unresolved`).
- `real-binary`: the AX evidence came from the process launched from
  `.build/debug/CodexUsageWidget` by this run (identity confirmed via `ps`).
- `observed_artifacts` keys are repo-relative and carry the sha256 of the
  exact bytes on disk, matching `_result()` in the coding closeout validator.

## Gotchas

- The `cua-driver` daemon must be running (`cua-driver status`); the CLI
  starts it, and Accessibility permission must be granted. Screen Recording
  permission is only needed for `card.png` (the AX tree proof stands without
  it).
- The closeout runs commands under a bare environment and a 2MiB file-size
  limit (RLIMIT_FSIZE). The script restores `HOME` from the passwd database
  when absent. When `swift build` cannot run under that limit — SwiftPM
  periodically refreshes multi-MB SDK caches (the SDK stat cache alone is
  ~15MB), which the limit rejects regardless of environment — the run may
  still continue with the existing binary, but only when the retained
  evidence's `inputs_digest` (a content digest of `Package.swift`,
  `Package.resolved`, and every file under `Sources/`) equals the current
  tree, so the driven binary is exactly the build of the digested inputs. A
  content change (or an evidence file without the digest) fails the check
  instead.
- Runs are serial by design: concurrent runs would share the demo preferences
  suite and interleave AX polling, though each run still kills only its own
  process group.
- `--ring` indexes the demo bars left-to-right (ring 0 is Codex account A);
  an out-of-range index simply never opens a card, which fails `open-card`.
- The closeout plan must list `build/qa/<id>/ax.json` under `artifacts` and
  include `script/verify_card.py` and this document in `dependencies`. The
  evidence run must happen before `check`: the validator requires the artifact
  to exist before the check and to stay byte-identical through it.
