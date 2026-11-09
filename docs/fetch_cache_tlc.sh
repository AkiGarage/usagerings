#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
[ -z "${TLA2TOOLS:-}" ] && [ -f "$HOME/.config/aki-formal/env" ] && . "$HOME/.config/aki-formal/env"
jar="${TLA2TOOLS_JAR:-${TLA2TOOLS:?set TLA2TOOLS_JAR}}"
java="${JAVA:-java}"
out=$(mktemp -d)
tlc() { "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers 1 -metadir "$out/$1" FetchCache.tla -config "$1.cfg" > "$out/$1.out" 2>&1; }
fail=0
tlc FetchCache
python_states=$(python3 -B fetch_cache_check.py | sed -n 's/^states=\([0-9]*\).*/\1/p')
tlc_states=$(grep -o '[0-9]* distinct states found' "$out/FetchCache.out" | head -1 | cut -d' ' -f1)
if grep -q "No error has been found" "$out/FetchCache.out" && [ "$tlc_states" = "$python_states" ]; then
  echo "PASS FetchCache $tlc_states distinct states (python mirror $python_states)"
else
  echo "FAIL FetchCache tlc=$tlc_states python=$python_states"; cat "$out/FetchCache.out"; fail=1
fi
tlc FetchCacheFault
if grep -q "Invariant InvNeverShowValueWhenGone is violated" "$out/FetchCacheFault.out" && ! python3 -B fetch_cache_check.py --fault >/dev/null; then
  echo "PASS FetchCacheFault caught InvNeverShowValueWhenGone (python mirror agrees)"
else
  echo "FAIL FetchCacheFault"; cat "$out/FetchCacheFault.out"; fail=1
fi
mv "$out" "${TMPDIR:-/tmp}/fetch-cache-tlc-archive-$$"
exit $fail
