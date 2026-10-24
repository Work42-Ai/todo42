#!/usr/bin/env bash
# build-todo42.sh — release build of todo42 as a small app bundle (todo42.app; the CLI is its executable), signed
# with a persistent Developer ID, the Hardened Runtime and todo42's own identifier.
#
# todo42 needs no macOS permission, so unlike meet42 nothing here is about usage strings. It is a bundle, signed
# under its own identifier (com.work42.todo42), so that:
#   1. it carries a stable Developer ID identity (not the ad-hoc signature `swift build` applies), which is what
#      lets Gatekeeper and notarization accept it, and
#   2. it has the same shape as the other Work42 tools (~/.work42/<tool>.app linked from ~/.work42/bin).
# Resources/todo42-Info.plist is embedded at link time (-sectcreate) and is also the bundle's Info.plist.
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" scripts/build-todo42.sh [--configuration release]
# Prints the path of the built todo42.app as its last line. Without DEVELOPER_ID it signs ad-hoc.
set -euo pipefail

CONFIG="release"
if [[ "${1:-}" == "--configuration" && -n "${2:-}" ]]; then CONFIG="$2"; fi

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$PKG_DIR/Resources/todo42-Info.plist"
ENTITLEMENTS="$PKG_DIR/Resources/todo42.entitlements"
IDENTIFIER="com.work42.todo42"

cd "$PKG_DIR"

echo "==> swift build (-c $CONFIG)" >&2
swift build -c "$CONFIG" --product todo42 \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" >&2

BIN="$(swift build -c "$CONFIG" --product todo42 --show-bin-path)/todo42"
echo "==> built $BIN" >&2

# Wrap the binary in todo42.app. The app has no window and no Dock icon (LSUIElement); the CLI is its executable.
APP="$PKG_DIR/.build/bundle/todo42.app"
VERSION="$(sed -n 's/^let todo42Version = "\(.*\)"$/\1/p' "$PKG_DIR/Sources/todo42/main.swift")"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/todo42"
cp "$PLIST" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" \
  -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
echo "==> bundled $APP (version $VERSION)" >&2

if [[ -z "${DEVELOPER_ID:-}" ]]; then
  echo "WARNING: DEVELOPER_ID not set — signing ad-hoc (fine for local use; not releasable)." >&2
  codesign --force --sign - --identifier "$IDENTIFIER" "$APP" >&2
  echo "$APP"
  exit 0
fi

echo "==> codesign ($IDENTIFIER, Hardened Runtime)" >&2
codesign --force --options runtime --timestamp \
  --identifier "$IDENTIFIER" --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID" "$APP" >&2
codesign -dv "$APP" 2>&1 | sed 's/^/    /' >&2
echo "$APP"
