#!/usr/bin/env bash
# Builds the Rust core as a static library and generates Swift bindings via UniFFI.
#   UNIVERSAL=1  build arm64 + x86_64 (requires `rustup target add x86_64-apple-darwin`)
#   PROFILE=debug|release (default release)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
PROFILE="${PROFILE:-release}"
OUT="$ROOT/build/core"
GEN_FFI="$ROOT/app/Sources/PbCoreFFI"
GEN_SWIFT="$ROOT/app/Sources/PbWindow/Generated"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

flag=""; [ "$PROFILE" = "release" ] && flag="--release"
host="$(rustc -vV | sed -n 's/^host: //p')"
targets=("$host")
[ "${UNIVERSAL:-0}" = "1" ] && targets=(aarch64-apple-darwin x86_64-apple-darwin)

libs=()
for t in "${targets[@]}"; do
  cargo build --manifest-path "$CORE/Cargo.toml" --lib $flag --target "$t"
  libs+=("$CORE/target/$t/$PROFILE/libpbcore.a")
done

mkdir -p "$OUT" "$GEN_FFI" "$GEN_SWIFT"
if [ "${#libs[@]}" -gt 1 ]; then
  lipo -create "${libs[@]}" -output "$OUT/libpbcore.a"
else
  cp "${libs[0]}" "$OUT/libpbcore.a"
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
(cd "$CORE" && cargo run --quiet --bin uniffi-bindgen -- \
  generate --library "${libs[0]}" --language swift --out-dir "$tmp")
cp "$tmp/pbcore.swift" "$GEN_SWIFT/pbcore.swift"
cp "$tmp/pbcoreFFI.h" "$GEN_FFI/pbcoreFFI.h"
cat > "$GEN_FFI/module.modulemap" <<MAP
module pbcoreFFI {
    header "pbcoreFFI.h"
    link "pbcore"
    export *
}
MAP
echo "core built: $OUT/libpbcore.a (${targets[*]})"
