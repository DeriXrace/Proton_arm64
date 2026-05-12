#!/usr/bin/env bash
# 04-package-wcp.sh
# Пакует /tmp/wine-staging в .wcp (tar.xz, переименованный в .wcp) для WinLator.
#
# Переменные:
#   STAGING_DIR   (default: /tmp/wine-staging)
#   OUTPUT_DIR    (default: /tmp)
#   OUTPUT_NAME   (default: wine-valve-arm64ec-proton11.wcp)
#   XZ_THREADS    (default: 0 = все ядра)
set -euo pipefail

log()  { printf '\033[1;36m[pack]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[pack]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[pack]\033[0m %s\n' "$*" >&2; exit 1; }

STAGING_DIR="${STAGING_DIR:-/tmp/wine-staging}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"
OUTPUT_NAME="${OUTPUT_NAME:-wine-valve-arm64ec-proton11.wcp}"
OUTPUT_PATH="$OUTPUT_DIR/$OUTPUT_NAME"
XZ_THREADS="${XZ_THREADS:-0}"

[[ -d "$STAGING_DIR" ]] || die "Нет $STAGING_DIR. Сначала запусти 03-build-wine.sh."
[[ -d "$STAGING_DIR/usr" ]] || die "$STAGING_DIR/usr отсутствует — staging пустой."

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_PATH"

log "Упаковываю $STAGING_DIR → $OUTPUT_PATH"
log "xz threads: $XZ_THREADS"

# Параллельный xz через переменную окружения XZ_OPT.
# tar архивирует содержимое STAGING_DIR (./usr/...), чтобы при распаковке в корень
# контейнера WinLator файлы легли в /usr/bin, /usr/lib и т.д.
(
    cd "$STAGING_DIR"
    XZ_OPT="-T${XZ_THREADS} -9" tar -cJf "$OUTPUT_PATH" .
)

SIZE="$(du -sh "$OUTPUT_PATH" | cut -f1)"
log "Готово: $OUTPUT_PATH  ($SIZE)"

# mini-verify: должны быть usr/bin/wine и usr/lib/wine/arm64ec-windows внутри
log "Проверка содержимого архива..."
tar -tJf "$OUTPUT_PATH" | grep -E '^\./usr/(bin/wine|lib/wine/arm64ec-windows/)' \
    | head -n5 || warn "В архиве не видно ключевых arm64ec файлов — посмотри вывод выше."

log "Перенеси $OUTPUT_PATH на устройство и импортируй в WinLator: Contents → Wine → Import."
