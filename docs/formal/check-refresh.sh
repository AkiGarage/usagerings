#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
[ -z "${TLA2TOOLS_JAR:-}${TLA2TOOLS:-}" ] && [ -f "$HOME/.config/aki-formal/env" ] && . "$HOME/.config/aki-formal/env"
jar="${TLA2TOOLS_JAR:-${TLA2TOOLS:?set TLA2TOOLS_JAR}}"
java="${JAVA:-java}"
out="${1:-$(mktemp -d)}"
mkdir -p "$out"
tlc() { "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers 1 -metadir "$out/$1" "${2:-UsageRefresh}.tla" -config "$1.cfg" > "$out/$1.out" 2>&1; }
fail=0
tlc UsageRefresh
if grep -q "No error has been found" "$out/UsageRefresh.out"; then echo "PASS UsageRefresh $(grep -o '[0-9]* distinct states found' "$out/UsageRefresh.out" | tail -1)"; else echo "FAIL UsageRefresh"; cat "$out/UsageRefresh.out"; fail=1; fi
for f in Fault-*.cfg; do
  n=${f%.cfg}
  tlc "$n"
  inv=$(grep '^INVARIANT' "$f" | tail -1 | cut -d' ' -f2)
  if grep -q "Invariant $inv is violated" "$out/$n.out"; then echo "PASS $n caught $inv"; else echo "FAIL $n did not catch $inv"; fail=1; fi
done
tlc ProviderBudget ProviderBudget
if grep -q "No error has been found" "$out/ProviderBudget.out"; then echo "PASS ProviderBudget $(grep -o '[0-9]* distinct states found' "$out/ProviderBudget.out" | tail -1)"; else echo "FAIL ProviderBudget"; cat "$out/ProviderBudget.out"; fail=1; fi
for f in BudgetFault-*.cfg; do
  n=${f%.cfg}
  tlc "$n" ProviderBudget
  inv=$(grep '^INVARIANT' "$f" | tail -1 | cut -d' ' -f2)
  if grep -q "Invariant $inv is violated" "$out/$n.out"; then echo "PASS $n caught $inv"; else echo "FAIL $n did not catch $inv"; cat "$out/$n.out"; fail=1; fi
done
echo "evidence: $out"
exit $fail
