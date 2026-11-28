#!/usr/bin/env bash
# Build the BeatScript engine for Apple platforms from the Android app's own UniFFI crate: `djmobile` in
# stackdump/beatscript-app rust/ (the crate, the `Player` and the btw_* functions the Play build drives),
# never a fork. Static libs for iOS device, iOS simulator (arm64) and macOS (arm64, for `swift test`),
# packaged as rust/dist/djmobileFFI.xcframework, plus the UniFFI Swift bindings in
# Sources/BeatScriptEngine/djmobile.swift.
#
# Sources (rust/PINS):
#   beatscript-app <rev>   the crate, fetched by git at build time into rust/src/beatscript-app (a cache clone;
#                          `git archive` of the rev into rust/upstream/; nothing is written to that repo, and
#                          nothing from it is committed here: the bindings and fixtures it yields are ignored)
#   beatscript <rev>       stackdump/beatscript (public), the engine crates. The snapshot's Cargo.toml has every
#                          beatscript rev rewritten to this one (what beatscript-app's own pin bumps do) and
#                          `cargo update -p djengine -p djhost -p djlive -p beatscript-api -p beatscript-seal` moves the lock.
#                          djrust, djrust-wallet and windwheel are set to the revs the engine's root Cargo.toml
#                          pins, so the lock holds one rev per git source (checked: two would link two djrusts).
#                          Empty: the crate's own pin is used and the build is --locked.
# `UPDATE=1` re-pins both to origin/main and rewrites rust/PINS.
#
# FEATURES: the crate's cargo features (default "network": pairing with beatscript.app, private pushes).
# The crate is `cdylib + lib`; `cargo rustc --crate-type staticlib` gives the .a without editing its Cargo.toml.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/rust"; U="$R/upstream"; PIN="$R/PINS"; SRC="$R/src"
APP_URL="${BEATSCRIPT_APP_URL:-git@github.com:stackdump/beatscript-app.git}"
BS_URL="https://github.com/stackdump/beatscript"
FEATURES="${FEATURES-network}"

mkdir -p "$SRC"
if [ -d "$SRC/beatscript-app/.git" ]; then git -C "$SRC/beatscript-app" fetch -q origin
else git clone -q --no-checkout "$APP_URL" "$SRC/beatscript-app"; fi

if [ "${UPDATE:-0}" = 1 ] || [ ! -f "$PIN" ] || ! grep -q '^beatscript-app ' "$PIN"; then
  bs=$(git ls-remote "$BS_URL" refs/heads/main | cut -f1)
  { echo "beatscript-app $(git -C "$SRC/beatscript-app" rev-parse "${APP_REF:-origin/main}")"
    echo "beatscript $bs"; } > "$PIN"
fi
APP_REV=$(awk '$1=="beatscript-app"{print $2}' "$PIN")
BS_REV=$(awk '$1=="beatscript"{print $2}' "$PIN")

# snapshot (re-extracted only when a pin changes)
key="$APP_REV ${BS_REV:-own}"
CRATE="$U/beatscript-app/rust"
if [ "$(cat "$U/.beatscript-app.rev" 2>/dev/null)" != "$key" ]; then
  rm -rf "${U:?}/beatscript-app"; mkdir -p "$U/beatscript-app"
  git -C "$SRC/beatscript-app" archive "$APP_REV" rust | tar -x -C "$U/beatscript-app"
  if [ -n "$BS_REV" ]; then
    sed -E -i '' "s#(git = \"$BS_URL\", rev = \")[0-9a-f]+#\1$BS_REV#g" "$CRATE/Cargo.toml"
    # djrust, djrust-wallet and windwheel follow the revs the engine's root Cargo.toml pins (the crate says they
    # must): otherwise the crate's own older djrust pin links a second djrust beside the engine's.
    ROOT_TOML=$(curl -fsSL "https://raw.githubusercontent.com/stackdump/beatscript/$BS_REV/Cargo.toml")
    for url in https://github.com/stackdump/djrust https://github.com/stackdump/windwheel-bitwrap-io; do
      rev=$(printf '%s\n' "$ROOT_TOML" | grep -o "git = \"$url\", rev = \"[0-9a-f]*" | sed 's/.*rev = "//' | sort -u)
      [ "$(printf '%s\n' "$rev" | grep -c .)" = 1 ] || { echo "engine root Cargo.toml: no single rev for $url: $rev" >&2; exit 1; }
      sed -E -i '' "s#(git = \"$url\", rev = \")[0-9a-f]+#\1$rev#g" "$CRATE/Cargo.toml"
    done
    (cd "$CRATE" && cargo update -q -p djengine -p djhost -p djlive -p beatscript-api -p beatscript-seal \
      -p djrust -p djrust-wallet -p windwheel)
  fi
  # fixes the pinned crate needs against this engine rev (until beatscript-app carries them itself)
  for p in "$R"/patches/*.patch; do [ -f "$p" ] && patch -p1 -d "$U/beatscript-app" < "$p"; done
  echo "$key" > "$U/.beatscript-app.rev"; echo "snapshot beatscript-app @ ${APP_REV:0:7}, beatscript @ ${BS_REV:0:7}"
fi
LOCK=--locked; [ -n "$BS_REV" ] && LOCK=""
grep -o "$BS_URL\", rev = \"[0-9a-f]*" "$CRATE/Cargo.toml" | sort -u | sed 's/.*rev = "/beatscript engine rev: /'
# one rev per git source in the lock, or two copies of a crate are linked
gitsrc() { grep '^source = "git+' "$CRATE/Cargo.lock" | sed -E 's/^source = "git\+([^?]*)\?rev=([0-9a-f]+).*/\1 \2/' | sort -u; }
dup=$(gitsrc | awk '{n[$1]++} END {for (u in n) if (n[u] > 1) print u}')
[ -z "$dup" ] || { echo "more than one rev of: $dup" >&2; exit 1; }
gitsrc | sed 's/^/  locked: /'

export CARGO_TARGET_DIR="$R/target"
# line tables only; the app dead-strips. Keep the .a small enough to handle.
export CARGO_PROFILE_RELEASE_DEBUG=0
export IPHONEOS_DEPLOYMENT_TARGET=18.0 MACOSX_DEPLOYMENT_TARGET=15.0
T="$CARGO_TARGET_DIR"; D="$R/dist"; X="$D/djmobileFFI.xcframework"
SLICES=${SLICES:-"aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin"}
FEAT=(); [ -n "$FEATURES" ] && FEAT=(--features "$FEATURES")
cd "$CRATE"
for t in $SLICES; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
  cargo rustc $LOCK --release --lib --target "$t" "${FEAT[@]}" --crate-type staticlib
done
rm -rf "$D" "$T/bindings"; mkdir -p "$D"
host_lib="$T/aarch64-apple-darwin/release/libdjmobile.a"
[ -f "$host_lib" ] || host_lib="$T/aarch64-apple-ios-sim/release/libdjmobile.a"
cargo run $LOCK -q --release "${FEAT[@]}" --bin uniffi-bindgen -- generate \
  --library "$host_lib" --language swift --out-dir "$T/bindings"
slice() { # id target archs platform [variant]
  local lib="$T/$2/release/libdjmobile.a"; [ -f "$lib" ] || return 0
  mkdir -p "$X/$1/Headers"; cp "$lib" "$X/$1/libdjmobile.a"
  cp "$T/bindings/djmobileFFI.h" "$X/$1/Headers/"
  cp "$T/bindings/djmobileFFI.modulemap" "$X/$1/Headers/module.modulemap"
  v=""; [ -n "${5:-}" ] && v="<key>SupportedPlatformVariant</key><string>$5</string>"
  printf '<dict><key>HeadersPath</key><string>Headers</string><key>LibraryIdentifier</key><string>%s</string><key>LibraryPath</key><string>libdjmobile.a</string><key>SupportedArchitectures</key><array>%s</array><key>SupportedPlatform</key><string>%s</string>%s</dict>' \
    "$1" "$(for a in $3; do printf '<string>%s</string>' $a; done)" "$4" "$v" >> "$D/entries.xml"
}
: > "$D/entries.xml"
slice ios-arm64 aarch64-apple-ios arm64 ios
slice ios-arm64-simulator aarch64-apple-ios-sim arm64 ios simulator
slice macos-arm64 aarch64-apple-darwin arm64 macos
{ echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>AvailableLibraries</key><array>'
  cat "$D/entries.xml"
  echo '</array><key>CFBundlePackageType</key><string>XFWK</string><key>XCFrameworkFormatVersion</key><string>1.0</string></dict></plist>'; } > "$X/Info.plist"
rm "$D/entries.xml"; plutil -lint "$X/Info.plist"
mkdir -p "$ROOT/Sources/BeatScriptEngine" && cp "$T/bindings/djmobile.swift" "$ROOT/Sources/BeatScriptEngine/djmobile.swift"

# the parity fixtures the XCTests read: the same files the crate's btw_parity / generate_parity read
F="$ROOT/Tests/BeatScriptParityTests/Fixtures"; rm -rf "$F"; mkdir -p "$F/beatscript-examples"
cp "$CRATE/tests/beatscript_golden.json" "$CRATE/tests/generate_fixtures.json" "$F/"
cp "$CRATE"/beatscript-examples/*.beatscript "$F/beatscript-examples/"
# and the engine's own CID pins at the pinned rev (crates/beatscript-api/tests/cid-pins.json: every program in
# stackdump/beatscript, the CIDs beatscript.app computes), with the programs it names, from cargo's checkout
BS_ROOT=$(cd "$CRATE" && cargo metadata -q --format-version 1 --offline | python3 -c '
import json, os, sys
m = json.load(sys.stdin)
print(next(os.path.dirname(os.path.dirname(os.path.dirname(p["manifest_path"]))) for p in m["packages"] if p["name"] == "djlive"))')
P="$BS_ROOT/crates/beatscript-api/tests/cid-pins.json"
mkdir -p "$F/engine-pins"; cp "$P" "$F/engine-pins/"
python3 -c 'import json, sys; print("\n".join(json.load(open(sys.argv[1]))))' "$P" | while read -r rel; do
  mkdir -p "$F/engine-pins/$(dirname "$rel")"; cp "$BS_ROOT/$rel" "$F/engine-pins/$rel"
done
echo "$key" > "$F/PIN"
du -sh "$X"; echo "xcframework: rust/dist/djmobileFFI.xcframework (pins: rust/PINS)"
