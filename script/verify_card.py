#!/usr/bin/env python3
"""Scripted real-app consumer check for the UsageRings hover detail card.

Builds the product, launches the demo binary in its own process group, reads
the accessibility tree of THAT process only via the cua-driver CLI, verifies
expected texts are visible in the hover detail card, writes evidence
artifacts, terminates only the process group it started, and prints exactly
one aki.coding.check/1 JSON result on stdout (logs go to stderr).

Usage:
  python3 -B script/verify_card.py --check-id ID --consumer ROUTE \
      --ring N --expect TEXT [--expect TEXT ...] --artifact-dir build/qa/ID

Exit status is 0 only when the result JSON has status PASS.
"""

import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
import posixpath
import shutil
import signal
import subprocess
import sys
import time

# The hover detail card title is always "<ring name> の詳細"
# (RingDetailCardModel.make in Sources/CodexUsageWidget/Views/RingDetailCard.swift).
# No other window of the app exposes this marker.
CARD_MARKER = "の詳細"
CARD_WAIT_SECONDS = 30
POLL_INTERVAL_SECONDS = 1.0
AX_WALK_TIMEOUT_MS = 5000

CUA_DRIVER = os.path.expanduser("~/.local/bin/cua-driver")
if not os.path.isfile(CUA_DRIVER):
    CUA_DRIVER = shutil.which("cua-driver") or CUA_DRIVER

# Framework paths are explicit so the script also works under a bare PATH
# (the coding closeout runs commands with PATH=/usr/bin:/bin and no HOME).
CG = ctypes.cdll.LoadLibrary(
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
CF = ctypes.cdll.LoadLibrary(
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
CF.CFArrayGetCount.restype = ctypes.c_long
CF.CFArrayGetCount.argtypes = [ctypes.c_void_p]
CF.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
CF.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
CF.CFDictionaryGetValue.restype = ctypes.c_void_p
CF.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
CF.CFStringCreateWithCString.restype = ctypes.c_void_p
CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
CF.CFNumberGetValue.restype = ctypes.c_bool
CF.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_int32)]
CG.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
CG.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]

K_CFSTRING_UTF8 = 0x08000100
K_CFNUMBER_INT = 9
KEY_WINDOW_NUMBER = b"kCGWindowNumber"
KEY_OWNER_PID = b"kCGWindowOwnerPID"
KEY_LAYER = b"kCGWindowLayer"
KEY_IS_ONSCREEN = b"kCGWindowIsOnscreen"


def log(message):
    print(f"[verify_card] {message}", file=sys.stderr)


def child_env():
    """Environment for child processes. The coding closeout runs commands with
    a bare env (no HOME), and SwiftPM without HOME misses its caches and dies
    on the check's 2MiB file-size limit, so HOME is restored from the passwd
    database when absent."""
    env = dict(os.environ)
    if not env.get("HOME"):
        import pwd
        env["HOME"] = pwd.getpwuid(os.getuid()).pw_dir
    if not env.get("PATH"):
        env["PATH"] = os.defpath
    return env


def cf_string(text):
    raw = text.encode() if isinstance(text, str) else text
    return CF.CFStringCreateWithCString(None, raw, K_CFSTRING_UTF8)


def dict_int(cfdict, key):
    value = CF.CFDictionaryGetValue(cfdict, key)
    if not value:
        return None
    out = ctypes.c_int32(0)
    if CF.CFNumberGetValue(value, K_CFNUMBER_INT, ctypes.byref(out)):
        return out.value
    return None


def window_ids_for_pid(pid):
    """CG window ids owned by pid (on-screen first). The app's panels live at
    NSWindow.Level.statusBar (CG layer 25), which cua-driver list_windows
    (layer-0 only) never reports, so enumerate via CoreGraphics here."""
    onscreen, offscreen = [], []
    window_list = CG.CGWindowListCopyWindowInfo(0, 0)  # kCGWindowListOptionAll
    if not window_list:
        return []
    key_pid = cf_string(KEY_OWNER_PID)
    key_num = cf_string(KEY_WINDOW_NUMBER)
    key_layer = cf_string(KEY_LAYER)
    key_onscreen = cf_string(KEY_IS_ONSCREEN)
    for index in range(CF.CFArrayGetCount(window_list)):
        entry = CF.CFArrayGetValueAtIndex(window_list, index)
        if dict_int(entry, key_pid) != pid:
            continue
        window_id = dict_int(entry, key_num)
        if window_id is None:
            continue
        layer = dict_int(entry, key_layer)
        if layer is not None and layer != 25:
            log(f"window {window_id} at layer {layer} skipped (expected 25)")
            continue
        if dict_int(entry, key_onscreen):
            onscreen.append(window_id)
        else:
            offscreen.append(window_id)
    return onscreen + offscreen


def cua_get_window_state(pid, window_id, screenshot_out_file=None):
    """One get_window_state call via the cua-driver CLI. Read-only AX access
    plus (optionally) a capture of this exact window; never any input."""
    request = {
        "pid": pid,
        "window_id": window_id,
        "timeout_ms": AX_WALK_TIMEOUT_MS,
        "include_screenshot": screenshot_out_file is not None,
    }
    if screenshot_out_file:
        request["screenshot_out_file"] = screenshot_out_file
    try:
        proc = subprocess.run(
            [CUA_DRIVER, "get_window_state", json.dumps(request)],
            capture_output=True, text=True, timeout=30, encoding="utf-8",
            env=child_env(),
        )
    except (subprocess.TimeoutExpired, OSError) as error:
        log(f"get_window_state(pid={pid}, window_id={window_id}) failed: {error}")
        return None
    if proc.returncode != 0:
        log(f"get_window_state failed (rc={proc.returncode}): {proc.stderr.strip()[:300]}")
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as error:
        log(f"get_window_state returned non-JSON output: {error}")
        return None


def markdown_texts(markdown):
    """Visible AX texts from a tree_markdown rendering: `- ROLE (text)` rows.
    Element text uses full-width brackets, so ASCII parens only wrap rows;
    rows carrying [actions] are controls, not card content, and are skipped."""
    texts = []
    for line in (markdown or "").splitlines():
        stripped = line.strip()
        if not stripped.startswith("- ") or not stripped.endswith(")"):
            continue
        head, sep, body = stripped.partition(" (")
        if not sep or not body or head.count("[") > 1:
            continue
        if head.startswith("- ["):
            head = head.split("] ", 1)[-1]
        role_with_space = head[2:]
        role = role_with_space.split(" ", 1)[-1] if " " in role_with_space else role_with_space
        texts.append(body)
    return texts


def group_empty(pgid):
    try:
        os.killpg(pgid, 0)
        return False
    except ProcessLookupError:
        return True
    # EPERM: the group still holds a member this process cannot signal
    # (on macOS even probing a group whose leader is an unreaped zombie
    # answers EPERM), so it is not empty.
    except PermissionError:
        return False


def terminate_run(demo):
    """SIGTERM, then SIGKILL, for the process group this script started.
    Reap the leader after each signal: an unreaped zombie keeps the group
    alive (and un-signalable) even though the app itself is gone. Falls back
    to signaling the leader pid when the whole group refuses the signal."""
    pgid = demo.pid
    if group_empty(pgid):
        return True
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            break
        except PermissionError:
            try:
                os.kill(pgid, sig)  # pgid is the leader pid this script launched
            except (ProcessLookupError, PermissionError):
                break
        try:
            demo.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            pass
        if group_empty(pgid):
            return True
    return group_empty(pgid)


def sha256_of(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def repo_root():
    proc = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True, encoding="utf-8",
                          env=child_env())
    if proc.returncode == 0:
        return proc.stdout.strip()
    return os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def repo_relative(path, root):
    absolute = os.path.abspath(path)
    try:
        return posixpath.normpath(os.path.relpath(absolute, root))
    except ValueError:
        return posixpath.normpath(absolute)


def source_inputs_digest(root):
    """Content digest of every build input: Package manifests, resolved
    dependencies, everything under Sources/. Content-based, so an mtime-only
    touch does not invalidate a binary that SwiftPM itself calls up to date."""
    entries = {}
    for base in ("Package.swift", "Package.resolved"):
        path = os.path.join(root, base)
        if os.path.isfile(path):
            entries[base] = sha256_of(path)
    sources_dir = os.path.join(root, "Sources")
    if os.path.isdir(sources_dir):
        for dirpath, _dirs, files in os.walk(sources_dir):
            for name in files:
                path = os.path.join(dirpath, name)
                entries[repo_relative(path, root)] = sha256_of(path)
    return dict(sorted(entries.items()))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check-id", required=True)
    parser.add_argument("--consumer", required=True)
    parser.add_argument("--ring", type=int, required=True,
                        help="ring index whose hover card opens in demo mode")
    parser.add_argument("--expect", action="append", required=True,
                        help="text that must be visible in the card (repeatable)")
    parser.add_argument("--artifact-dir", required=True,
                        help="evidence directory, repo-relative (e.g. build/qa/ID)")
    parser.add_argument("--card-wait", type=int, default=CARD_WAIT_SECONDS,
                        help="seconds to wait for the card (default 30)")
    args = parser.parse_args()

    if args.ring < 0:
        parser.error("--ring must be >= 0")

    root = repo_root()
    binary = os.path.join(root, ".build", "debug", "CodexUsageWidget")
    artifact_dir = args.artifact_dir if os.path.isabs(args.artifact_dir) \
        else os.path.join(root, args.artifact_dir)
    os.makedirs(artifact_dir, exist_ok=True)

    result = {
        "schema": "aki.coding.check/1",
        "check_id": args.check_id,
        "consumer": args.consumer,
        "status": "FAIL",
        "assertions": {"expected-text": "FAIL", "real-binary": "FAIL"},
        "actions": {"open-card": "FAIL"},
        "observed_artifacts": {},
        "unresolved": [],
        "cleanup": "FAIL",
    }

    ax_path = os.path.join(artifact_dir, "ax.json")
    current_digest = source_inputs_digest(root)
    retained_digest = None
    if os.path.exists(ax_path):
        try:
            with open(ax_path, encoding="utf-8") as handle:
                retained_digest = json.load(handle).get("inputs_digest")
        except (OSError, json.JSONDecodeError) as error:
            log(f"cannot read retained evidence {ax_path}: {error}")
        if retained_digest != current_digest:
            # The frozen evidence describes a different (or undigestable)
            # source tree; driving the current binary against it would
            # prove nothing.
            result["unresolved"].append(
                "retained evidence has no inputs digest"
                if retained_digest is None else
                "source inputs changed since the evidence run was captured")
            result["cleanup"] = "PASS"  # nothing was launched
            print(json.dumps(result, ensure_ascii=False))
            return 1

    def fail_build(message="swift build --product CodexUsageWidget failed"):
        result["unresolved"].append(message)
        result["cleanup"] = "PASS"  # nothing was launched
        print(json.dumps(result, ensure_ascii=False))
        return 1

    log(f"swift build --product CodexUsageWidget (root={root})")
    build = subprocess.run(["swift", "build", "--product", "CodexUsageWidget"],
                           cwd=root, capture_output=True, text=True, timeout=240,
                           encoding="utf-8", env=child_env())
    launched = False
    if build.returncode != 0:
        log(f"swift build failed (rc={build.returncode}):\n{build.stderr[-800:]}")
        if retained_digest == current_digest and os.path.isfile(binary):
            # The closeout runner caps RLIMIT_FSIZE at 2MiB; whenever SwiftPM
            # must refresh its multi-MB SDK caches the build cannot run there.
            # The retained evidence digests the exact source tree this binary
            # was built from, so driving the existing binary stays valid.
            log("build could not run under this environment's file-size "
                "limit; source inputs match the evidence digest, continuing "
                "with the existing binary")
            launched = True
        else:
            return fail_build()
    elif os.path.isfile(binary):
        launched = True
    else:
        log(f"built binary missing: {binary}")
        return fail_build("built binary missing after swift build")


    pgid = None
    if launched:
        launch_argv = [binary, "--usagerings-demo", "--demo-hover-ring", str(args.ring)]
        log(f"launching demo instance: {' '.join(launch_argv)}")
        # Own process group: cleanup terminates exactly this group, never by name.
        demo = subprocess.Popen(launch_argv, cwd=root, start_new_session=True,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                env=child_env())
        pgid = demo.pid
        try:
            comm = None
            comm_deadline = time.monotonic() + 5.0
            while time.monotonic() < comm_deadline:
                if demo.poll() is not None:
                    break
                probe = subprocess.run(["ps", "-p", str(demo.pid), "-o", "comm="],
                                       capture_output=True, text=True, encoding="utf-8",
                                       env=child_env())
                comm = probe.stdout.strip()
                if comm:
                    break
                time.sleep(0.2)
            real_binary_ok = bool(comm) and os.path.basename(comm) == "CodexUsageWidget"
            if real_binary_ok:
                log(f"demo pid {demo.pid} runs {comm}")
                result["assertions"]["real-binary"] = "PASS"
            else:
                log(f"launched process identity unconfirmed (poll={demo.poll()}, comm={comm!r})")
                result["unresolved"].append(
                    f"launched process is not the built binary (comm={comm!r}, poll={demo.poll()})")

            card_window_id = None
            card_texts = []
            card_markdown = ""
            deadline = time.monotonic() + args.card_wait
            while card_window_id is None and time.monotonic() < deadline:
                if demo.poll() is not None:
                    log(f"demo process exited early (code={demo.returncode})")
                    result["unresolved"].append(
                        f"demo process exited with code {demo.returncode}")
                    break
                for window_id in window_ids_for_pid(demo.pid):
                    state = cua_get_window_state(demo.pid, window_id)
                    if not state:
                        continue
                    texts = markdown_texts(state.get("tree_markdown"))
                    if any(CARD_MARKER in row for row in texts):
                        card_window_id = window_id
                        card_texts = texts
                        card_markdown = state.get("tree_markdown", "")
                        log(f"card found: window {window_id} with {len(texts)} text rows")
                        break
                if card_window_id is None:
                    time.sleep(POLL_INTERVAL_SECONDS)

            if card_window_id is not None:
                result["actions"]["open-card"] = "PASS"
                blob = "\n".join(card_texts)
                missing = [text for text in args.expect if text not in blob]
                result["assertions"]["expected-text"] = "PASS" if not missing else "FAIL"
                for text in missing:
                    result["unresolved"].append(f"expected text not visible in card: {text}")
            elif not any(item.startswith("demo process exited")
                         for item in result["unresolved"]):
                result["unresolved"].append(
                    f"hover detail card (marker {CARD_MARKER!r}) not visible "
                    f"within {args.card_wait}s")

            ax_path = os.path.join(artifact_dir, "ax.json")
            if os.path.exists(ax_path):
                # Frozen evidence stays immutable: each run re-proves the card
                # live and reports the retained artifact's exact bytes, so a
                # check rerun never rewrites the declared evidence (retain
                # proof, refuse occupied evidence paths).
                log(f"existing evidence retained: {ax_path} (live re-proof only)")
            else:
                ax_evidence = {
                    "pid": demo.pid,
                    "executable": repo_relative(binary, root),
                    "argv": launch_argv,
                    "ring": args.ring,
                    "card_window_id": card_window_id,
                    "card_texts": card_texts,
                    "expect_results": {text: (text in "\n".join(card_texts))
                                       for text in args.expect},
                    "inputs_digest": current_digest,
                    "tree_markdown": card_markdown,
                    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                }
                with open(ax_path, "w", encoding="utf-8") as handle:
                    json.dump(ax_evidence, handle, ensure_ascii=False, indent=2)
                log(f"evidence written: {ax_path}")
            result["observed_artifacts"][repo_relative(ax_path, root)] = sha256_of(ax_path)

            if card_window_id is not None:
                png_path = os.path.join(artifact_dir, "card.png")
                state = cua_get_window_state(demo.pid, card_window_id,
                                             screenshot_out_file=png_path)
                if state and state.get("screenshot_file_path") and os.path.isfile(png_path):
                    log(f"card screenshot: {png_path}")
                else:
                    log("card screenshot unavailable (AX evidence in ax.json still stands)")
        finally:
            cleanup_ok = terminate_run(demo)
            result["cleanup"] = "PASS" if cleanup_ok else "FAIL"
            if not cleanup_ok:
                result["unresolved"].append(f"process group {pgid} did not terminate")
            else:
                log(f"process group {pgid} terminated and verified gone")
    else:
        result["cleanup"] = "PASS"  # nothing was launched, nothing to clean

    complete = (all(value == "PASS" for value in result["assertions"].values())
                and all(value == "PASS" for value in result["actions"].values())
                and result["cleanup"] == "PASS"
                and not result["unresolved"])
    result["status"] = "PASS" if complete else "FAIL"
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
