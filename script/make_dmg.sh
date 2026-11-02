#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-adhoc}"
APP="$ROOT_DIR/dist/UsageRings.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Support/Info-Multi.plist")"
OUT="$ROOT_DIR/dist/UsageRings-$VERSION-$MODE.dmg"

case "$MODE" in
  adhoc)
    USAGERINGS_SIGN_IDENTITY="-" "$ROOT_DIR/script/build_and_run.sh" multi package
    ;;
  developer-id)
    IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -F'"' '/"Developer ID Application:/ { print $2; exit }')"
    if [[ -z "$IDENTITY" ]]; then
      echo "make_dmg: no Developer ID Application identity in the keychain" >&2
      exit 2
    fi
    USAGERINGS_SIGN_IDENTITY="-" "$ROOT_DIR/script/build_and_run.sh" multi package
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
    while IFS= read -r nested; do
      /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
    done < <(/usr/bin/find "$SPARKLE/Versions/B" \( -name "*.xpc" -o -name "*.app" \) -prune -print; /usr/bin/find "$SPARKLE/Versions/B" -maxdepth 1 -name Autoupdate)
    /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE"
    /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    /usr/bin/codesign --verify --strict --deep "$APP"
    ;;
  *)
    echo "usage: make_dmg.sh [adhoc|developer-id]" >&2
    exit 2
    ;;
esac

STAGE="$(mktemp -d)"
trap 'mv "$STAGE" "${TMPDIR:-/tmp}/usagerings-dmg-stage-archive-$$"' EXIT
/usr/bin/ditto "$APP" "$STAGE/UsageRings.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT_DIR/Support/dmg/README-CodexBar.txt" "$STAGE/README - CodexBar required.txt"
if [[ -e "$OUT" ]]; then
  mkdir -p "$ROOT_DIR/dist/archive"
  mv "$OUT" "$ROOT_DIR/dist/archive/$(basename "$OUT" .dmg)-$(date +%Y%m%d%H%M%S).dmg"
fi
/usr/bin/hdiutil create -quiet -volname "UsageRings $VERSION" -srcfolder "$STAGE" -format UDZO "$OUT"
/usr/bin/hdiutil verify -quiet "$OUT"
echo "$OUT"
if [[ "$MODE" == "developer-id" ]]; then
  echo "next (needs approval): xcrun notarytool submit \"$OUT\" --keychain-profile <profile> --wait && xcrun stapler staple \"$OUT\""
fi
