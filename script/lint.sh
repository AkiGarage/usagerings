#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
status=0

fail() {
  echo "lint: $1" >&2
  status=1
}

if grep -rniE 'cliproxy|8317|v0/management' Sources Tests script README.md README.ja.md SECURITY.md docs --exclude=lint.sh; then
  fail "CLIProxyAPI references are banned"
fi

if grep -rnE '"--source", *"(web|oauth|cookie|auto|api)"|kSecClassGenericPassword|SecItemCopyMatching' Sources; then
  fail "provider reads must use --source cli and must not read the Keychain"
fi

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  if [[ ! -f "$file" ]]; then
    fail "comment-free file missing: $file"
    continue
  fi
  if grep -nE '^[[:space:]]*(//|/\*)' "$file" || grep -nE '[;{})][[:space:]]+//' "$file"; then
    fail "comments are banned in $file"
  fi
done < script/lint/comment-free.txt

exit "$status"
