#!/usr/bin/env bash
# Builds the Rust core + Swift app and assembles build/Clipvault.app.
#   SIGN_IDENTITY  codesign identity (default "-" = ad-hoc)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Clipvault.app"

"$ROOT/scripts/build-core.sh"
swift build -c release --package-path "$ROOT/app" ${UNIVERSAL:+--arch arm64 --arch x86_64}
BIN="$(swift build -c release --package-path "$ROOT/app" ${UNIVERSAL:+--arch arm64 --arch x86_64} --show-bin-path)/Clipvault"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clipvault"
cp "$ROOT/app/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "built: $APP"
