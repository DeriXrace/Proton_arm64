#!/usr/bin/env bash
# 05-repack-for-winlator.sh
# Перепаковывает staging-каталог Wine в формат, понимаемый WinLator Bionic Ludashi.
#
# WinLator ожидает структуру:
#   proton-<version>/
#   ├── bin/wineserver (и wine, wineboot, winecfg)
#   ├── lib/wine/{aarch64-unix,aarch64-windows,arm64ec-windows,i386-windows}
#   ├── share/wine/
#   ├── prefixPack/           (пустая папка — WinLator сам создаст prefix)
#   ├── prefixPack.txz        (или пустой — WinLator сам инициализирует)
#   └── profile.json          (ОБЯЗАТЕЛЬНО — описание пакета)
#
# Использование:
#   bash scripts/05-repack-for-winlator.sh
#
# Env:
#   STAGING_DIR    (default: /work/wine-staging или /tmp/wine-staging)
#   OUTPUT_DIR     (default: /output или /sdcard/steam/out)
#   VERSION_NAME   (default: 11.0-arm64ec)
#   OUTPUT_NAME    (default: proton-$VERSION_NAME.wcp)
set -euo pipefail

log()  { printf '\033[1;36m[repack]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[repack]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[repack]\033[0m %s\n' "$*" >&2; exit 1; }

STAGING_DIR="${STAGING_DIR:-/work/wine-staging}"
[[ -d "$STAGING_DIR" ]] || STAGING_DIR="/tmp/wine-staging"
[[ -d "$STAGING_DIR" ]] || die "Нет staging: $STAGING_DIR"

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
[[ -d "$OUTPUT_DIR" ]] || OUTPUT_DIR="/sdcard/steam/out"
mkdir -p "$OUTPUT_DIR"

VERSION_NAME="${VERSION_NAME:-11.0-arm64ec}"
PACK_NAME="proton-${VERSION_NAME}"
OUTPUT_NAME="${OUTPUT_NAME:-${PACK_NAME}.wcp}"
OUTPUT_PATH="$OUTPUT_DIR/$OUTPUT_NAME"

REPACK_DIR="$(mktemp -d)"
trap 'rm -rf "$REPACK_DIR"' EXIT

DEST="$REPACK_DIR/$PACK_NAME"
mkdir -p "$DEST"

# ---- 1. Определить исходный каталог (usr/ или прямой) ----
if [[ -d "$STAGING_DIR/usr/lib/wine" ]]; then
    SRC="$STAGING_DIR/usr"
elif [[ -d "$STAGING_DIR/lib/wine" ]]; then
    SRC="$STAGING_DIR"
else
    die "Не нашёл lib/wine ни в $STAGING_DIR/usr, ни в $STAGING_DIR"
fi

log "Источник: $SRC"
log "Назначение: $DEST"

# ---- 2. Копируем нужные каталоги ----
# bin/ — только runtime-бинарники
mkdir -p "$DEST/bin"
for bin in wine wine64 wineserver wineboot winecfg; do
    if [[ -f "$SRC/bin/$bin" ]]; then
        cp -a "$SRC/bin/$bin" "$DEST/bin/"
    fi
done

# lib/wine/ — целиком (DLL, .so модули)
if [[ -d "$SRC/lib/wine" ]]; then
    cp -a "$SRC/lib/wine" "$DEST/lib/"
fi
# Иногда lib64/ тоже бывает
if [[ -d "$SRC/lib64/wine" ]]; then
    cp -a "$SRC/lib64/wine" "$DEST/lib/"
fi

# share/wine/ — nls, fonts, wine.inf
if [[ -d "$SRC/share/wine" ]]; then
    mkdir -p "$DEST/share"
    cp -a "$SRC/share/wine" "$DEST/share/"
fi

# ---- 3. prefixPack (пустая папка + пустой txz) ----
mkdir -p "$DEST/prefixPack"
# Создаём минимальный пустой txz (WinLator сам инициализирует prefix через wineboot)
tar -cJf "$DEST/prefixPack.txz" --files-from=/dev/null

# ---- 4. profile.json ----
cat > "$DEST/profile.json" <<EOF
{
  "type": "Proton",
  "versionName": "${VERSION_NAME}",
  "versionCode": 1,
  "description": "Proton ${VERSION_NAME} - Wine ARM64EC build from DeriXrace/Proton_arm64",
  "files": [],
  "wine": {
    "binPath": "bin",
    "libPath": "lib",
    "prefixPack": "prefixPack.txz"
  }
}
EOF

# ---- 5. Статистика ----
log "Содержимое $PACK_NAME:"
echo "  bin/:"
ls "$DEST/bin/" 2>/dev/null | sed 's/^/    /'
echo "  lib/wine/:"
ls "$DEST/lib/wine/" 2>/dev/null | sed 's/^/    /'
echo "  share/wine/:"
ls "$DEST/share/wine/" 2>/dev/null | sed 's/^/    /'
echo "  profile.json: $(wc -c < "$DEST/profile.json") bytes"
echo "  prefixPack.txz: $(wc -c < "$DEST/prefixPack.txz") bytes"

# ---- 6. Упаковка в .wcp ----
log "Упаковываю в $OUTPUT_PATH ..."
rm -f "$OUTPUT_PATH"
( cd "$REPACK_DIR" && XZ_OPT="-T0 -6" tar -cJf "$OUTPUT_PATH" "$PACK_NAME" )

SIZE="$(du -sh "$OUTPUT_PATH" | cut -f1)"
log "Готово: $OUTPUT_PATH ($SIZE)"
log ""
log "Импортируй в WinLator: Contents → Wine / Proton → Import"
