#!/usr/bin/env bash
# 04-package-wcp.sh — упаковка в .wcp для WinLator (с генерацией prefix)
set -euo pipefail

STAGING_DIR="${STAGING_DIR:-/work/wine-staging}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
VERSION_NAME="${VERSION_NAME:-11.0-arm64ec}"
OUTPUT_PATH="$OUTPUT_DIR/proton-${VERSION_NAME}.wcp"

[ -d "$STAGING_DIR/usr/lib/wine" ] || { echo "ОШИБКА: нет $STAGING_DIR/usr/lib/wine"; exit 1; }
mkdir -p "$OUTPUT_DIR"

SRC="$STAGING_DIR/usr"

# --- 1. Генерация Wine prefix через wineboot ---
echo "[pack] Генерация Wine prefix (wineboot --init)..."
export WINEPREFIX=/tmp/wineprefix
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree=;mshtml="
export WINEDEBUG="-all"
export PATH="$SRC/bin:$PATH"
export LD_LIBRARY_PATH="$SRC/lib:${LD_LIBRARY_PATH:-}"

rm -rf "$WINEPREFIX" && mkdir -p "$WINEPREFIX"
timeout 300 wineboot --init 2>&1 | tail -5 || true
wineserver -w 2>/dev/null || true

if [ -d "$WINEPREFIX/drive_c" ]; then
    echo "[pack] Prefix OK: $(du -sh $WINEPREFIX | cut -f1)"
else
    echo "[pack] WARN: wineboot не создал drive_c"
fi

# --- 2. Собираем структуру ---
echo "[pack] Собираю структуру .wcp..."
rm -rf /tmp/repack && mkdir /tmp/repack
cp -a "$SRC/bin" /tmp/repack/
cp -a "$SRC/lib" /tmp/repack/
cp -a "$SRC/share" /tmp/repack/ 2>/dev/null || true

# Удаляем dev-утилиты и include
rm -f /tmp/repack/bin/widl /tmp/repack/bin/winegcc /tmp/repack/bin/wineg++ \
      /tmp/repack/bin/winebuild /tmp/repack/bin/wmc /tmp/repack/bin/wrc \
      /tmp/repack/bin/winemaker /tmp/repack/bin/winedump \
      /tmp/repack/bin/function_grep.pl /tmp/repack/bin/winecpp
rm -rf /tmp/repack/include

# --- 3. prefixPack.txz ---
if [ -d "$WINEPREFIX/drive_c" ]; then
    ( cd "$WINEPREFIX" && XZ_OPT="-T0 -6" tar -cJf /tmp/repack/prefixPack.txz . )
    echo "[pack] prefixPack.txz: $(du -sh /tmp/repack/prefixPack.txz | cut -f1)"
else
    tar -cJf /tmp/repack/prefixPack.txz --files-from=/dev/null
    echo "[pack] prefixPack.txz: пустой (wineboot не сработал)"
fi

# --- 4. profile.json ---
cat > /tmp/repack/profile.json <<EOF
{
  "type": "Proton",
  "versionName": "${VERSION_NAME}",
  "versionCode": 1,
  "description": "Proton ${VERSION_NAME} - DeriXrace custom build",
  "files": [],
  "wine": {
    "binPath": "bin",
    "libPath": "lib",
    "prefixPack": "prefixPack.txz"
  }
}
EOF

# --- 5. Упаковка (плоский архив) ---
echo "[pack] Упаковка .wcp..."
rm -f "$OUTPUT_PATH"
( cd /tmp/repack && XZ_OPT="-T0 -6" tar -cJf "$OUTPUT_PATH" . )

echo ""
echo "=========================================="
echo "  ГОТОВО: $OUTPUT_PATH"
echo "  Размер: $(du -sh "$OUTPUT_PATH" | cut -f1)"
echo "=========================================="
echo "lib/wine:"
ls /tmp/repack/lib/wine/
echo "bin:"
ls /tmp/repack/bin/ | head -20
echo ""
echo "WinLator → Contents → Proton → Import"
