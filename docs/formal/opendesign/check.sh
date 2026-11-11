#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -z "${TLA2TOOLS_JAR:-}${TLA2TOOLS:-}" && -f "$HOME/.config/aki-formal/env" ]]; then
    source "$HOME/.config/aki-formal/env"
fi
jar="${TLA2TOOLS_JAR:-${TLA2TOOLS:?set TLA2TOOLS_JAR}}"
out="${1:?pass an absolute evidence directory}"
mkdir -p "$out"
for pair in OpenDesignRead:OpenDesignRead VerticalTabFit:VerticalTabFit OpenDesignRead:Fault-Disabled OpenDesignRead:Fault-Invalid OpenDesignRead:Fault-Forbidden VerticalTabFit:Fault-Overwrite VerticalTabFit:Fault-NoFit VerticalTabFit:Fault-Stuck; do
    model="${pair%%:*}"; cfg="${pair##*:}"
    rc=0
    "${JAVA:-java}" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers 1 -metadir "$out/$cfg-states" "$model.tla" -config "$cfg.cfg" > "$out/$cfg.log" 2>&1 || rc=$?
    if [[ "$cfg" = Fault-* ]]; then
        invariant=$(awk '/^INVARIANT/ {print $2}' "$cfg.cfg")
        if [[ $rc -eq 0 ]] || ! grep -q "Invariant $invariant is violated" "$out/$cfg.log"; then
            cat "$out/$cfg.log"; exit 1
        fi
        echo "PASS $cfg caught $invariant"
    else
        if [[ $rc -ne 0 ]] || ! grep -q 'No error has been found' "$out/$cfg.log"; then
            cat "$out/$cfg.log"; exit 1
        fi
        echo "PASS $cfg"
    fi
done
