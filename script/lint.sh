#!/usr/bin/env bash
set -euo pipefail
cd "${LINT_ROOT:-$(dirname "$0")/..}"
status=0

fail() {
  echo "lint: $1" >&2
  status=1
}

scan() {
  local message="$1" pattern="$2"
  shift 2
  local path
  for path in "$@"; do
    [[ -e "$path" ]] || fail "lint target missing: $path"
  done
  local found
  found="$(grep -rnE "$pattern" "$@" --exclude=lint.sh --exclude=lint-selftest.sh 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    echo "$found" >&2
    fail "$message"
  fi
}

scan "CLIProxyAPI references are banned" '[Cc][Ll][Ii][Pp][Rr][Oo][Xx][Yy]|8317|v[0-9]+/management' Sources Tests script README.md README.ja.md SECURITY.md docs
scan "provider reads must use --source cli and must not read the Keychain" '"--source", *"(web|oauth|cookie|auto|api)"|kSecClassGenericPassword|SecItemCopyMatching' Sources
scan "README must not claim sections work without CodexBarCLI" 'work independently when that helper is missing|独立して動作します' README.md README.ja.md

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  if [[ ! -f "$file" ]]; then
    fail "comment-free file missing: $file"
    continue
  fi
  if grep -nE '(^|[^:"/])//|/\*' "$file" | grep -vE '"[^"]*//[^"]*"' ; then
    fail "comments are banned in $file"
  fi
done < script/lint/comment-free.txt

exit "$status"
