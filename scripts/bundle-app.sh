#!/usr/bin/env bash
# Builds the Rust core + Swift app and assembles build/Clipvault.app.
#   SIGN_IDENTITY  codesign identity (default "-" = ad-hoc)
#   UNIVERSAL=1    universal binary (arm64 + x86_64)
#   VERSION        CFBundleShortVersionString (default: from Info.plist)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Clipvault.app"
PLIST="$APP/Contents/Info.plist"

"$ROOT/scripts/build-core.sh"
triples=()
[ "${UNIVERSAL:-0}" = "1" ] && triples=(arm64-apple-macosx x86_64-apple-macosx)

bins=()
if [ "${#triples[@]}" -eq 0 ]; then
  swift build -c release --package-path "$ROOT/app"
  bins+=("$(swift build -c release --package-path "$ROOT/app" --show-bin-path)/Clipvault")
else
  for t in "${triples[@]}"; do
    swift build -c release --package-path "$ROOT/app" --triple "$t"
    bins+=("$(swift build -c release --package-path "$ROOT/app" --triple "$t" --show-bin-path)/Clipvault")
  done
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${#bins[@]}" -gt 1 ]; then
  lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/Clipvault"
else
  cp "${bins[0]}" "$APP/Contents/MacOS/Clipvault"
fi
cp "$ROOT/app/Resources/Info.plist" "$PLIST"
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION#v}" "$PLIST"
fi
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "built: $APP"
