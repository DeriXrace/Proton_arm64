#!/usr/bin/env bash
# 04-package-wcp.sh — Package wine-staging into .wcp for WinLator Bionic Ludashi
#
# IMPORTANT:
# - prefixPack.txz is EMPTY. WinLator runs its own wineboot on first container launch.
#   A pre-generated prefix from proot CONFLICTS with WinLator's ARM64EC container init.
# - Archive is FLAT: ./bin/ ./lib/ ./share/ ./profile.json ./prefixPack.txz at root.
# - lib/wine/ MUST contain arm64ec-windows/ — without it WinLator hangs forever.
set -euo pipefail

STAGING_DIR="${STAGING_DIR:-/work/wine-staging}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
VERSION_NAME="${VERSION_NAME:-11.0-arm64ec}"
OUTPUT_PATH="$OUTPUT_DIR/proton-${VERSION_NAME}.wcp"

[ -d "$STAGING_DIR/usr/lib/wine" ] || { echo "FATAL: no $STAGING_DIR/usr/lib/wine"; exit 1; }
mkdir -p "$OUTPUT_DIR"

SRC="$STAGING_DIR/usr"

# --- 1. Verify arm64ec-windows exists BEFORE packaging ---
if [ ! -d "$SRC/lib/wine/arm64ec-windows" ]; then
    echo ""
    echo "FATAL: arm64ec-windows/ MISSING from $SRC/lib/wine/"
    echo "Cannot package .wcp without arm64ec DLLs — WinLator will hang forever."
    echo ""
    echo "Contents of lib/wine/:"
    ls "$SRC/lib/wine/"
    echo ""
    echo "Fix: rebuild with arm64ec toolchain in PATH (source /opt/llvm-mingw.env)"
    echo "     and pass arm64ec_CC=arm64ec-w64-mingw32-clang to configure"
    exit 1
fi

ARM64EC_COUNT=$(ls "$SRC/lib/wine/arm64ec-windows" | wc -l)
echo "[pack] arm64ec-windows: $ARM64EC_COUNT DLLs — OK"

# --- 2. Assemble flat structure ---
echo "[pack] Assembling .wcp structure..."
rm -rf /tmp/repack && mkdir /tmp/repack

# Copy bin/ (all runtime binaries)
cp -a "$SRC/bin" /tmp/repack/

# Copy lib/ (all wine modules)
cp -a "$SRC/lib" /tmp/repack/

# Copy share/ (nls, fonts, wine.inf)
cp -a "$SRC/share" /tmp/repack/ 2>/dev/null || true

# Remove dev tools (not needed in runtime)
rm -f /tmp/repack/bin/widl /tmp/repack/bin/winegcc /tmp/repack/bin/wineg++ \
      /tmp/repack/bin/winebuild /tmp/repack/bin/wmc /tmp/repack/bin/wrc \
      /tmp/repack/bin/winemaker /tmp/repack/bin/winedump \
      /tmp/repack/bin/function_grep.pl /tmp/repack/bin/winecpp

# Remove include/ (dev headers, not needed)
rm -rf /tmp/repack/include

# --- 3. prefixPack.txz — EMPTY ---
# WinLator Bionic runs its own wineboot on first container launch.
# Pre-generated prefix from proot Linux conflicts with ARM64EC container init.
tar -cJf /tmp/repack/prefixPack.txz --files-from=/dev/null
echo "[pack] prefixPack.txz: empty (WinLator generates prefix itself)"

# --- 4. profile.json ---
cat > /tmp/repack/profile.json <<EOF
{
  "type": "Proton",
  "versionName": "${VERSION_NAME}",
  "versionCode": 1,
  "description": "Proton ${VERSION_NAME} - DeriXrace ARM64EC build",
  "files": [],
  "wine": {
    "binPath": "bin",
    "libPath": "lib",
    "prefixPack": "prefixPack.txz"
  }
}
EOF

# --- 5. Final verification ---
echo "[pack] Verifying structure..."
echo "  bin/ ($(ls /tmp/repack/bin/ | wc -l) files):"
ls /tmp/repack/bin/ | sed 's/^/    /'
echo "  lib/wine/:"
ls /tmp/repack/lib/wine/ | sed 's/^/    /'
echo "  profile.json: present"
echo "  prefixPack.txz: present (empty)"

# Verify all 4 required directories
for dir in aarch64-unix aarch64-windows arm64ec-windows i386-windows; do
    if [ -d "/tmp/repack/lib/wine/$dir" ]; then
        count=$(ls "/tmp/repack/lib/wine/$dir" | wc -l)
        echo "    $dir: $count files"
    else
        echo "  WARNING: $dir MISSING"
    fi
done

# --- 6. Package as flat .wcp (no wrapper directory!) ---
echo "[pack] Creating $OUTPUT_PATH ..."
rm -f "$OUTPUT_PATH"
( cd /tmp/repack && XZ_OPT="-T0 -6" tar -cJf "$OUTPUT_PATH" . )

SIZE="$(du -sh "$OUTPUT_PATH" | cut -f1)"
echo ""
echo "=========================================="
echo "  DONE: $OUTPUT_PATH"
echo "  Size: $SIZE"
echo "=========================================="
echo ""
echo "  Archive top-level (must be flat — no subdirectory):"
tar -tJf "$OUTPUT_PATH" | head -8 | sed 's/^/    /'
echo ""
echo "  Install: WinLator → Contents → Proton → Import"
