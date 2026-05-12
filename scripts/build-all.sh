#!/usr/bin/env bash
# build-all.sh — запускает 01→02→03→04 по порядку (внутри proot ubuntu)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_step() {
    local name="$1" script="$2"
    echo ""
    echo "[build-all] === $name ==="
    if ! bash "$SCRIPT_DIR/$script"; then
        echo "[build-all] Шаг '$name' ($script) упал."
        exit 1
    fi
    echo "[build-all] === $name: OK ==="
}

START_TS=$(date +%s)

if [ "${SKIP_DEPS:-0}" != "1" ]; then
    run_step "1/4 install-deps" "01-install-deps.sh"
else
    echo "[build-all] Пропускаю 01-install-deps.sh (SKIP_DEPS=1)"
fi

if [ "${SKIP_TOOLCHAIN:-0}" != "1" ]; then
    run_step "2/4 setup-toolchain" "02-setup-toolchain.sh"
else
    echo "[build-all] Пропускаю 02-setup-toolchain.sh (SKIP_TOOLCHAIN=1)"
fi

# Подключаем toolchain
[ -f /opt/llvm-mingw.env ] && source /opt/llvm-mingw.env

run_step "3/4 build-wine" "03-build-wine.sh"
run_step "4/4 package-wcp" "04-package-wcp.sh"

END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))
echo ""
echo "[build-all] Всё готово. Время: $((ELAPSED/60))м $((ELAPSED%60))с"
