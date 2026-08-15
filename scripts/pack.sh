#!/bin/bash
# Builds the release binary and packs it into a .mcpb Claude extension bundle.
#
# An .mcpb is a zip with manifest.json at its root. There is no dependency on the
# `mcpb` CLI here: zip is enough, and it keeps the toolchain to what macOS ships.
set -euo pipefail

NAME="whatsapp-mcp"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Universal, so the bundle also runs on an Intel Mac. Drop the second --arch for a
# faster local build.
echo "==> Building $NAME (universal)"
swift build -c release --arch arm64 --arch x86_64

BINARY=".build/apple/Products/Release/$NAME"
[ -f "$BINARY" ] || BINARY=".build/release/$NAME"
[ -f "$BINARY" ] || { echo "!! no release binary found" >&2; exit 1; }

echo "==> Staging bundle"
STAGE="$ROOT/extension"
rm -rf "$STAGE/server"
mkdir -p "$STAGE/server"
cp "$BINARY" "$STAGE/server/$NAME"
chmod +x "$STAGE/server/$NAME"

# There is no TCC identity to establish here, and no embedded Info.plist to protect:
# this server reads one file in a group container macOS does not protect, and sends no
# Apple event to anything. The signature below is therefore about distribution, not
# permissions — an ad-hoc signature is enough to run, and MCPB_SIGN_IDENTITY is only
# needed for something meant to be handed to another machine.
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
