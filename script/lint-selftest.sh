#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'mv "$work" "${TMPDIR:-/tmp}/lint-selftest-archive-$$"' EXIT

expect_fail() {
  local name="$1"
  rm -rf "$work/root"
  mkdir -p "$work/root"
  (cd "$repo" && tar cf - Sources Tests script README.md README.ja.md SECURITY.md docs) | (cd "$work/root" && tar xf -)
  "$2" "$work/root"
  if LINT_ROOT="$work/root" bash "$repo/script/lint.sh" >/dev/null 2>&1; then
    echo "lint-selftest: lint missed $name" >&2
    exit 1
  fi
}

trailing_comment() { echo 'let x = 5 // note' >> "$1/$(head -1 "$1/script/lint/comment-free.txt")"; }
block_comment() { echo 'let y = 6 /* c */' >> "$1/$(head -1 "$1/script/lint/comment-free.txt")"; }
management_url() { echo 'let u = "http://127.0.0.1:9000/v8/management/x"' >> "$1/Sources/CodexUsageWidget/Services/MultiUsageService.swift"; }
missing_target() { mv "$1/docs" "$1/docs-gone"; }
web_source() { echo 'let a = ["--source", "web"]' >> "$1/Sources/CodexUsageWidget/Services/MultiUsageService.swift"; }
cli_path_literal() { echo 'let p = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"' >> "$1/Sources/CodexUsageWidget/Services/MultiUsageService.swift"; }
guide_moved() { python3 -c "import sys;p=sys.argv[1];s=open(p).read().replace('            codexBarGuide.start()\n','',1).replace('        persona.start()','        persona.start()\n        codexBarGuide.start()',1);open(p,'w').write(s)" "$1/Sources/CodexUsageWidget/App/AppDelegate.swift"; }
test_path_literal() { echo 'let q = "/Applications/CodexBar.app"' >> "$1/Tests/CodexUsageWidgetTests/CodexBarRequirementTests.swift"; }
guide_removed() { sed -i.bak 's/codexBarGuide.start()/codexBarGuide.state/' "$1/Sources/CodexUsageWidget/App/AppDelegate.swift"; }
isolated_deinit() { printf 'final class Z {\n    isolated deinit {}\n}\n' >> "$1/Sources/CodexUsageWidget/Services/MultiUsageService.swift"; }
readme_claim() { echo 'Other sections can work independently when that helper is missing.' >> "$1/README.md"; }

for case in trailing_comment block_comment management_url missing_target web_source readme_claim cli_path_literal guide_removed guide_moved test_path_literal isolated_deinit; do
  expect_fail "$case" "$case"
done
bash "$repo/script/lint.sh"
echo "lint-selftest: ok"
