#!/usr/bin/env bash
# 05-repack-for-winlator.sh
# Перепаковывает staging Wine в .wcp для WinLator Bionic Ludashi.
#
# Референс — рабочий proton-11.0-1-arm64ec.wcp от сообщества:
#   ./bin/wine, wineserver, winecfg, wineboot, notepad, regedit, winedbg, ...
#   ./lib/wine/{aarch64-unix,aarch64-windows,arm64ec-windows,i386-windows}
#   ./share/wine/
#   ./prefixPack.txz   (содержит готовый .wine prefix)
#   ./profile.json
#   (корень архива ПЛОСКИЙ, БЕЗ wrapper-папки)
#
# Env:
#   STAGING_DIR      (default /work/wine-staging)
#   OUTPUT_DIR       (default /output)
#   VERSION_NAME     (default 11.0-arm64ec)
#   GEN_PREFIX=1     сгенерировать реальный .wine через wineboot (5-10 мин)
#                    без флага — пустой prefixPack.txz (WinLator сам инит).
#   FORCE=1          перезаписывать существующий .wcp
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
OUTPUT_NAME="${OUTPUT_NAME:-proton-${VERSION_NAME}.wcp}"
OUTPUT_PATH="$OUTPUT_DIR/$OUTPUT_NAME"

GEN_PREFIX="${GEN_PREFIX:-0}"

REPACK_DIR="$(mktemp -d)"
trap 'rm -rf "$REPACK_DIR"' EXIT

# ---- 1. Определить исходный каталог ----
if [[ -d "$STAGING_DIR/usr/lib/wine" ]]; then
    SRC="$STAGING_DIR/usr"
elif [[ -d "$STAGING_DIR/lib/wine" ]]; then
    SRC="$STAGING_DIR"
else
    die "Не нашёл lib/wine ни в $STAGING_DIR/usr, ни в $STAGING_DIR"
fi

log "Источник:   $SRC"
log "Назначение: $OUTPUT_PATH"

# ---- 2. Копируем bin/, lib/, share/ ЦЕЛИКОМ (ничего не фильтруем) ----
# Исключаем только include/ (dev-headers, в runtime не нужны).
log "Копирую bin/, lib/wine/, share/wine/ целиком..."
cp -a "$SRC/bin"       "$REPACK_DIR/" 2>/dev/null || warn "Нет bin/"
cp -a "$SRC/lib"       "$REPACK_DIR/" 2>/dev/null || warn "Нет lib/"
[[ -d "$SRC/lib64" ]]  && cp -a "$SRC/lib64"/* "$REPACK_DIR/lib/" 2>/dev/null || true
[[ -d "$SRC/share" ]]  && cp -a "$SRC/share"   "$REPACK_DIR/"

# ---- 3. prefixPack.txz ----
if [[ "$GEN_PREFIX" == "1" ]]; then
    log "GEN_PREFIX=1: генерирую Wine prefix через wineboot (это займёт 5-15 минут)..."
    PREFIX_WORK="$(mktemp -d)"
    WINEPREFIX_DIR="$PREFIX_WORK/.wine"

    # Нужен рабочий wine-бинарь. Есть в $SRC/bin. Ему нужен loader с lib/wine.
    export WINEPREFIX="$WINEPREFIX_DIR"
    export WINEARCH="win64"
    export WINEDLLOVERRIDES="mscoree=;mshtml="  # не качать .NET/Gecko
    export WINEDEBUG="-all"
    # Временно ставим PATH чтобы wine нашёл wineserver
    export PATH="$SRC/bin:$PATH"

    WINE_BIN=""
    for candidate in "$SRC/bin/wine64" "$SRC/bin/wine"; do
        if [[ -x "$candidate" ]]; then
            WINE_BIN="$candidate"
            break
        fi
    done

    if [[ -z "$WINE_BIN" ]]; then
        warn "Не нашёл wine бинарь в $SRC/bin — делаю пустой prefixPack.txz"
        tar -cJf "$REPACK_DIR/prefixPack.txz" --files-from=/dev/null
    else
        log "Запускаю: $WINE_BIN wineboot --init"
        mkdir -p "$WINEPREFIX_DIR"
        if timeout 600 "$WINE_BIN" wineboot --init 2>&1 | tail -30; then
            "$WINE_BIN"server -w 2>/dev/null || true
            if [[ -d "$WINEPREFIX_DIR/drive_c" ]]; then
                log "Prefix сгенерирован: $(du -sh "$WINEPREFIX_DIR" | cut -f1)"
                log "Упаковываю .wine → prefixPack.txz..."
                ( cd "$PREFIX_WORK" && XZ_OPT="-T0 -6" tar -cJf "$REPACK_DIR/prefixPack.txz" .wine )
            else
                warn "wineboot не создал drive_c — делаю пустой prefixPack.txz"
                tar -cJf "$REPACK_DIR/prefixPack.txz" --files-from=/dev/null
            fi
        else
            warn "wineboot упал или тайм-аут — делаю пустой prefixPack.txz"
            tar -cJf "$REPACK_DIR/prefixPack.txz" --files-from=/dev/null
        fi
    fi
    rm -rf "$PREFIX_WORK"
else
    log "GEN_PREFIX=0: создаю пустой prefixPack.txz (WinLator сам инитит через wineboot)"
    tar -cJf "$REPACK_DIR/prefixPack.txz" --files-from=/dev/null
fi

# ---- 4. profile.json ----
cat > "$REPACK_DIR/profile.json" <<EOF
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
log "Содержимое:"
echo "  bin/ ($(ls "$REPACK_DIR/bin" 2>/dev/null | wc -l) файлов):"
ls "$REPACK_DIR/bin" 2>/dev/null | head -20 | sed 's/^/    /'
echo "  lib/wine/:"
ls "$REPACK_DIR/lib/wine" 2>/dev/null | sed 's/^/    /'
if ls "$REPACK_DIR/lib/wine/arm64ec-windows" >/dev/null 2>&1; then
    echo "    \033[1;32mОТЛИЧНО: arm64ec-windows/ ЕСТЬ\033[0m"
else
    printf '    \033[1;33mВНИМАНИЕ: arm64ec-windows/ НЕТ — configure не поймал arm64ec toolchain\033[0m\n'
fi
printf '  profile.json:    %s байт\n' "$(wc -c < "$REPACK_DIR/profile.json")"
printf '  prefixPack.txz:  %s\n' "$(du -h "$REPACK_DIR/prefixPack.txz" | cut -f1)"

# ---- 6. Упаковка в .wcp (ПЛОСКО — без wrapper-папки!) ----
[[ "${FORCE:-0}" == "1" || ! -f "$OUTPUT_PATH" ]] || die "$OUTPUT_PATH уже есть (FORCE=1 чтобы перезаписать)"

log "Упаковываю (flat — файлы в корне архива)..."
rm -f "$OUTPUT_PATH"
( cd "$REPACK_DIR" && XZ_OPT="-T0 -6" tar -cJf "$OUTPUT_PATH" . )

SIZE="$(du -sh "$OUTPUT_PATH" | cut -f1)"
log "Готово: $OUTPUT_PATH ($SIZE)"
log ""
log "Первые файлы в архиве (должны быть ./bin, ./lib, ./profile.json):"
tar -tJf "$OUTPUT_PATH" | head -10 | sed 's/^/  /'
log ""
log "Импортируй в WinLator: Contents → Proton → Import → $OUTPUT_NAME"
