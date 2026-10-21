#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/CodexUsageWidget.app" >&2
  exit 2
fi

APP_BUNDLE="$1"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

test -d "$APP_BUNDLE"
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
APP_EXECUTABLE="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$INFO_PLIST")"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"
SPARKLE_BINARY="$SPARKLE_FRAMEWORK/Versions/Current/Sparkle"

test -x "$APP_BINARY"
test -L "$SPARKLE_FRAMEWORK/Versions/Current"
test -x "$SPARKLE_BINARY"
/usr/bin/codesign --verify --strict --deep "$APP_BUNDLE"
/usr/bin/otool -L "$APP_BINARY" | /usr/bin/grep -F '@rpath/Sparkle.framework/' >/dev/null
/usr/bin/otool -l "$APP_BINARY" | /usr/bin/grep -F 'path @executable_path/../Frameworks ' >/dev/null

for architecture in $(/usr/bin/lipo -archs "$APP_BINARY"); do
  /usr/bin/lipo "$SPARKLE_BINARY" -verify_arch "$architecture"
done
