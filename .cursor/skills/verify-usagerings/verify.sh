#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
out="${1:-/tmp/usagerings-verify-$(date +%Y%m%d-%H%M%S)}"
case "$out" in /*) ;; *) echo "output dir must be absolute" >&2; exit 2 ;; esac
[ -e "$out" ] && { echo "output dir exists: $out" >&2; exit 2; }
cd "$root"
swift build >/dev/null
bin="$(swift build --show-bin-path)/CodexUsageWidget"
fw="$(find .build/artifacts -path '*macos*' -name Sparkle.framework -type d | head -1)"
DYLD_FRAMEWORK_PATH="$(dirname "$fw")" "$bin" --demo-export "$out" >/dev/null
fail=0
for f in panel-dark.png panel-light.png panel-failure-no-data.png rings-horizontal.png rings-vertical.png rings-warning-critical.png hover-opendesign.png rings-vertical-fitted.png; do
  if [ -s "$out/$f" ]; then echo "ok $f"; else echo "MISSING $f"; fail=1; fi
done
echo "evidence: $out"
exit $fail
