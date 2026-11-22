#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
[ -z "${TLA2TOOLS_JAR:-}${TLA2TOOLS:-}" ] && [ -f "$HOME/.config/aki-formal/env" ] && . "$HOME/.config/aki-formal/env"
jar="${TLA2TOOLS_JAR:-${TLA2TOOLS:?set TLA2TOOLS_JAR to tla2tools.jar}}"
java="${JAVA:-java}"
out=$(mktemp -d)
fail=0
tlc() { "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers 1 -metadir "$out/$2" "$1.tla" -config "$2.cfg" > "$out/$2.out" 2>&1; }
for pair in UsageRead:UsageRead CodexBarGate:CodexBarGate GeminiHalt:GeminiHalt; do
  tlc "${pair%%:*}" "${pair##*:}"
  if grep -q "No error has been found" "$out/${pair##*:}.out"; then echo "PASS ${pair##*:} $(grep -o '[0-9]* distinct states found' "$out/${pair##*:}.out" | tail -1)"
  else echo "FAIL ${pair##*:}"; cat "$out/${pair##*:}.out"; fail=1; fi
done
# Each fault turns off one real guard; TLC must report the named invariant.
tlc UsageRead ReadFault-RetryLogout
if grep -q "Invariant NoRetryOnLogout is violated" "$out/ReadFault-RetryLogout.out"; then echo "PASS ReadFault-RetryLogout caught NoRetryOnLogout"
else echo "FAIL ReadFault-RetryLogout not caught"; cat "$out/ReadFault-RetryLogout.out"; fail=1; fi
# GeminiHalt faults: one constant each, one violated property each.
tlc GeminiHalt Fault-GeminiHaltForever
if grep -qE "Temporal property HaltEventuallyRetried was violated|Error: Temporal properties were violated\." "$out/Fault-GeminiHaltForever.out"; then echo "PASS Fault-GeminiHaltForever caught HaltEventuallyRetried"
else echo "FAIL Fault-GeminiHaltForever not caught"; cat "$out/Fault-GeminiHaltForever.out"; fail=1; fi
for invpair in Fault-GeminiTransientHalts:TransientNeverHalts Fault-GeminiReadWhileHalted:NoReadWhileFreshHalt Fault-GeminiFabricate:NoFabrication; do
  tlc GeminiHalt "${invpair%%:*}"
  if grep -q "Invariant ${invpair##*:} is violated" "$out/${invpair%%:*}.out"; then echo "PASS ${invpair%%:*} caught ${invpair##*:}"
  else echo "FAIL ${invpair%%:*} did not catch ${invpair##*:}"; cat "$out/${invpair%%:*}.out"; fail=1; fi
done
rm -rf "$out"
exit $fail
