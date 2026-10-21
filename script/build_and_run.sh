#!/usr/bin/env bash
set -euo pipefail

VARIANT="classic"
if [[ "${1:-}" == "multi" || "${1:-}" == "usagerings" ]]; then
  VARIANT="multi"
  shift
fi

MODE="${1:-run}"
APP_NAME="CodexUsageWidget"
BUNDLE_ID="local.codex.CodexUsageWidget"
INFO_PLIST_SOURCE="Info.plist"
INSTALL_DIR=""

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

if [[ "$VARIANT" == "multi" ]]; then
  APP_NAME="UsageRings"
  BUNDLE_ID="com.akigarage.usagerings"
  INFO_PLIST_SOURCE="Info-Multi.plist"
  INSTALL_DIR="$HOME/Applications"
fi
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

if [[ "$MODE" == "--package-verify" || "$MODE" == "package-verify" ]]; then
  VERIFY_BUNDLE="${2:-$APP_BUNDLE}"
  exec "$ROOT_DIR/script/verify_app_bundle.sh" "$VERIFY_BUNDLE"
fi

if [[ "$MODE" != "--package" && "$MODE" != "package" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
if [[ "$VARIANT" == "multi" && "$MODE" != "--package" && "$MODE" != "package" ]] && pgrep -x "CodexUsageWidget-Multi" >/dev/null 2>&1; then
  # Never stop the pre-rename app automatically; it may be the one in daily use.
  echo "note: legacy CodexUsageWidget-Multi is still running; UsageRings will run beside it (quit the old one yourself)." >&2
fi

cd "$ROOT_DIR"
swift build -c release
BUILD_BINARY="$(swift build -c release --show-bin-path)/CodexUsageWidget"

mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
SPARKLE_FRAMEWORK="$(swift build -c release --show-bin-path)/Sparkle.framework"
test -d "$SPARKLE_FRAMEWORK"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"
cp "$ROOT_DIR/Support/$INFO_PLIST_SOURCE" "$INFO_PLIST"
cp "$ROOT_DIR/Support/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
if ! /usr/bin/otool -l "$APP_BINARY" | /usr/bin/grep -F 'path @executable_path/../Frameworks ' >/dev/null; then
  /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_BINARY"
fi
# Local builds use ad-hoc signing. Supply your own identity when needed.
SIGN_IDENTITY="${USAGERINGS_SIGN_IDENTITY:--}"
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

install_app() {
  if [[ -z "$INSTALL_DIR" ]]; then
    echo "install is only available for the multi variant" >&2
    exit 2
  fi
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_DIR/$APP_NAME.app"
}

case "$MODE" in
  run)
    if [[ "$VARIANT" == "multi" ]]; then
      install_app
      /usr/bin/open -n "$INSTALL_DIR/$APP_NAME.app"
    else
      open_app
    fi
    ;;
  install)
    install_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --package|package)
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [multi|usagerings] [run|install|--debug|--logs|--telemetry|--package|--verify|--package-verify [app]]" >&2
    exit 2
    ;;
esac
