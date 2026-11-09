#!/usr/bin/env python3
"""Exhaustive state-space check for docs/FetchCache.tla (TLC is not installed here).

Mirrors the TLA+ spec literally: same variables, same actions, same invariants.
  python3 -B docs/fetch_cache_check.py            -> checks the spec, exit 0
  python3 -B docs/fetch_cache_check.py --fault    -> checks the RetainOnLogout mutant, must exit 1
"""
import sys

HORIZON = 8


def expired(good_at, now, reset):
    return good_at != -1 and (now - good_at >= 5 or now >= reset)


def justifies_question(good_at, now, reset, logged_out):
    return good_at == -1 or expired(good_at, now, reset) or logged_out


def next_shown_after_fail(good_at, now, reset, logged_out, retain_on_logout):
    if retain_on_logout and logged_out:
        return "value"
    if justifies_question(good_at, now, reset, logged_out):
        return "?"
    return "value"


def actions(state, retain_on_logout):
    good_at, now, reset, logged_out, shown = state
    out = []
    if now < reset:
        out.append(("PollSuccess", (now, now, reset, False, "value")))
    out.append(("TransientFail", (good_at, now, reset, logged_out,
                                  next_shown_after_fail(good_at, now, reset, logged_out, retain_on_logout))))
    out.append(("LogoutFail", (good_at, now, reset, True, "value" if retain_on_logout else "?")))
    if now < HORIZON:
        out.append(("Tick", (good_at, now + 1, reset, logged_out,
                             next_shown_after_fail(good_at, now + 1, reset, logged_out, retain_on_logout))))
    return out


def invariants(state):
    good_at, now, reset, logged_out, shown = state
    if shown == "?" and not justifies_question(good_at, now, reset, logged_out):
        return "InvQuestionOnlyWhenJustified"
    if shown == "value" and (good_at == -1 or expired(good_at, now, reset) or logged_out):
        return "InvNeverShowValueWhenGone"
    return None


def main(retain_on_logout):
    seen = {}
    frontier = [(-1, 0, HORIZON, False, "?")]
    seen[frontier[0]] = "Init"
    violations = []
    while frontier:
        state = frontier.pop()
        bad = invariants(state)
        if bad:
            violations.append((bad, seen[state], state))
            continue
        for name, nxt in actions(state, retain_on_logout):
            if nxt not in seen:
                seen[nxt] = name
                frontier.append(nxt)
    print(f"states={len(seen)} retainOnLogout={retain_on_logout}")
    for invariant, action, state in violations[:5]:
        print(f"VIOLATION {invariant} after {action} at state goodAt={state[0]} now={state[1]} "
              f"reset={state[2]} loggedOut={state[3]} shown={state[4]}")
    if violations:
        print(f"FAILED: {len(violations)} violation(s)")
        return 1
    print("OK: all invariants hold")
    return 0


if __name__ == "__main__":
    sys.exit(main("--fault" in sys.argv))
