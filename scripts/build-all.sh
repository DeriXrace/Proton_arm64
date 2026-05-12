#!/usr/bin/env bash
# build-all.sh — прогоняет всю цепочку: deps → toolchain → build → package.
#
# Флаги (env):
#   SKIP_DEPS=1       — пропустить apt-get
#   SKIP_TOOLCHAIN=1  — пропустить скачивание llvm-mingw (если уже стоит)
#   SKIP_BUILD=1      — пропустить сборку wine
#   SKIP_PACK=1       — пропустить упаковку .wcp
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\n\033[1;35m[build-all]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[build-all]\033[0m %s\n' "$*" >&2; exit 1; }

run_step() {
    local name="$1"; shift
    local script="$1"; shift
    log "=== $name ==="
    if ! bash "$SCRIPT_DIR/$script" "$@"; then
        die "Шаг '$name' ($script) упал. Смотри вывод выше."
    fi
    log "=== $name: OK ==="
}

START_TS=$(date +%s)

if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
    run_step "1/4 install-deps"      "01-install-deps.sh"
else
    log "Пропускаю 01-install-deps.sh (SKIP_DEPS=1)"
fi

if [[ "${SKIP_TOOLCHAIN:-0}" != "1" ]]; then
    run_step "2/4 setup-toolchain"   "02-setup-toolchain.sh"
else
    log "Пропускаю 02-setup-toolchain.sh (SKIP_TOOLCHAIN=1)"
fi

# Подключаем env toolchain-а ДЛЯ последующих шагов (в рамках этого же процесса).
if [[ -f /opt/llvm-mingw.env ]]; then
    # shellcheck disable=SC1091
    source /opt/llvm-mingw.env
fi

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    run_step "3/4 build-wine"        "03-build-wine.sh"
else
    log "Пропускаю 03-build-wine.sh (SKIP_BUILD=1)"
fi

if [[ "${SKIP_PACK:-0}" != "1" ]]; then
    run_step "4/4 package-wcp"       "04-package-wcp.sh"
else
    log "Пропускаю 04-package-wcp.sh (SKIP_PACK=1)"
fi

END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))
log "Готово. Время: $((ELAPSED/60))м $((ELAPSED%60))с"
log "Ищи .wcp в /tmp/ (по умолчанию wine-valve-arm64ec-proton11.wcp)."
