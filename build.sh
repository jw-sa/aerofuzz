#!/bin/bash
# Builds dist/AeroFuzz.app.
#   ./build.sh            release build
#   ./build.sh --run      release build, then (re)launch it
set -euo pipefail
cd "$(dirname "$0")"

# Jeppe's Command Line Tools contain a stale 2023 swift/module.modulemap that redefines
# SwiftBridging and breaks every AppKit build; the overlay hides it (no sudo needed).
# Harmless on a clean toolchain — drop it once CLT is reinstalled.
OVERLAY="$PWD/toolchain-fix/overlay.yaml"
sed "s|__ROOT__|$PWD|" toolchain-fix/overlay.template.yaml > "$OVERLAY"
swift build -c release -Xswiftc -vfsoverlay -Xswiftc "$OVERLAY" -Xcc -ivfsoverlay -Xcc "$OVERLAY"

APP="dist/AeroFuzz.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AeroFuzz "$APP/Contents/MacOS/AeroFuzz"
cp Info.plist "$APP/Contents/Info.plist"
# Sign with a stable local certificate when it exists: macOS keys the Screen Recording grant
# on the signature, and ad-hoc signatures change on every build (= permission lost each time).
# Create it once with ./make-signing-cert.sh.
IDENTITY="AeroFuzz Local Signing"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  security unlock-keychain -p aerofuzz ~/Library/Keychains/aerofuzz.keychain-db
  codesign --force --sign "$IDENTITY" "$APP" 2>&1 | grep -v "replacing existing signature" || true
else
  echo "warning: '$IDENTITY' not found, signing ad-hoc (Screen Recording must be re-granted after every build)"
  codesign --force --sign - "$APP" >/dev/null 2>&1
fi

if [[ "${1:-}" == "--run" ]]; then
  pkill -x AeroFuzz || true
  sleep 0.3
  open "$APP"
fi
echo "Built $APP"
