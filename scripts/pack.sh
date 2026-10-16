#!/bin/bash
# Builds the release binary and packs it into a .mcpb Claude extension bundle.
#
# An .mcpb is a zip with manifest.json at its root. There is no dependency on the
# `mcpb` CLI here: zip is enough, and it keeps the toolchain to what macOS ships.
set -euo pipefail

NAME="whatsapp-mcp"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Apple silicon only. A universal build (--arch arm64 --arch x86_64) doubles the bundle
# and takes ~70x longer to link, and macOS 26 is the end of the road for Intel anyway.
echo "==> Building $NAME (arm64)"
swift build -c release

BINARY=".build/release/$NAME"
[ -f "$BINARY" ] || { echo "!! no release binary found" >&2; exit 1; }

# GUARD: Apple silicon only. A stray extra architecture would otherwise ship without
# any error.
ARCHS="$(lipo -archs "$BINARY")"
[ "$ARCHS" = "arm64" ] \
  || { echo "!! expected arm64 only, got: $ARCHS" >&2; exit 1; }

echo "==> Staging bundle"
STAGE="$ROOT/extension"
rm -rf "$STAGE/server"
mkdir -p "$STAGE/server"
cp "$BINARY" "$STAGE/server/$NAME"
chmod +x "$STAGE/server/$NAME"

# There is no embedded Info.plist, and none has been needed so far: audio_transcribe uses
# SpeechAnalyzer, which ran from this bare ad-hoc binary with no permission prompt and no
# usage description, and produced a transcript from the installed bundle under Claude
# Desktop. If macOS ever demands NSSpeechRecognitionUsageDescription, embed an Info.plist
# here with `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker <plist>`.
#
# The signature matters for something else: Full Disk Access, which reading WhatsApp's
# container needs, is granted to the exact program. An ad-hoc signature (the default) has
# a different identity on every build, so macOS forgets the grant after each rebuild and
# the person must grant it again — the README says so. A stable identity would keep it,
# BUT a certificate's subject carries its holder's name: never publish a binary signed
# with a personal certificate. MCPB_SIGN_IDENTITY is for local use or a pseudonymous one.
IDENTITY="${MCPB_SIGN_IDENTITY:--}"
echo "==> Signing with identity: $IDENTITY"
codesign --force --identifier "codes.eneko.$NAME" --sign "$IDENTITY" "$STAGE/server/$NAME"
codesign -dv "$STAGE/server/$NAME" 2>&1 | grep -oE 'flags=[^ ]*' | sed 's/^/    /' || true

python3 -c "import json,sys; json.load(open('$STAGE/manifest.json'))" \
  || { echo "!! manifest.json is not valid JSON" >&2; exit 1; }

echo "==> Packing"
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/$NAME.mcpb"
rm -f "$OUT"
# -X drops resource forks and extra attributes; the archive should contain only what
# the manifest describes.
( cd "$STAGE" && zip -qrX "$OUT" manifest.json icon.png server )

# The MCPB spec does not say whether the installer preserves the executable bit, so
# verify the archive at least records it. If a future Claude release drops it, the
# symptom is a server that never starts, and the fix is a chmod +x on the installed
# copy — see the README.
echo "==> Verifying the executable bit survived"
MODE=$(unzip -Z "$OUT" "server/$NAME" | awk 'NR==1 {print $1}')
case "$MODE" in
  *x*) echo "    mode $MODE — executable" ;;
  *)   echo "!! executable bit lost: $MODE" >&2; exit 1 ;;
esac

echo
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
echo "Install it by opening the file with Claude."
