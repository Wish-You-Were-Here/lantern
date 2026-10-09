#!/bin/bash
# Builds Lantern.app with swiftc (requires Xcode or Command Line Tools).
#   ./build.sh            builds to build/Lantern.app
#   ./build.sh --install  builds, copies to /Applications and launches
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Lantern.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Lantern"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" 2>/dev/null
echo "Built: $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Lantern 2>/dev/null || true
  for _ in $(seq 1 50); do pgrep -x Lantern >/dev/null || break; sleep 0.1; done
  rm -rf /Applications/Lantern.app
  cp -R "$APP" /Applications/
  open /Applications/Lantern.app
  echo "Installed to /Applications and launched."
fi
