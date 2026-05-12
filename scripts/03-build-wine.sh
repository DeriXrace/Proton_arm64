#!/usr/bin/env bash
# 03-build-wine.sh
# Собирает Wine (Valve, ветка proton_11.0) под ARM64EC + AArch64 + i386 (WOW64)
# и ставит в staging-директорию, которую потом упакует 04-package-wcp.sh.
#
# Переменные окружения (все опциональные):
#   WINE_SRC       — путь к уже склонированным исходникам wine.
#                    Если не задан: использует $REPO_ROOT (если это wine-репа),
#                    иначе клонирует ValveSoftware/wine в ./wine-src.
#   WINE_BRANCH    — ветка (default: proton_11.0)
#   BUILD_DIR      — где билдить (default: ./wine-build)
#   STAGING_DIR    — куда make install (default: /tmp/wine-staging)
#   JOBS           — параллелизм (default: nproc)
#   SKIP_CLONE=1   — не делать git clone, использовать WINE_SRC как есть
set -euo pipefail

log()  { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build]\033[0m %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

WINE_BRANCH="${WINE_BRANCH:-proton_11.0}"
WINE_REPO_URL="${WINE_REPO_URL:-https://github.com/ValveSoftware/wine.git}"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/wine-build}"
STAGING_DIR="${STAGING_DIR:-/tmp/wine-staging}"
JOBS="${JOBS:-$(nproc)}"

# ---------- 1. toolchain ----------
if [[ -z "${LLVM_MINGW_PATH:-}" ]]; then
    if [[ -f /opt/llvm-mingw.env ]]; then
        # shellcheck disable=SC1091
        source /opt/llvm-mingw.env
    else
        die "llvm-mingw не настроен. Запусти scripts/02-setup-toolchain.sh."
    fi
fi
command -v arm64ec-w64-mingw32-clang >/dev/null 2>&1 \
    || die "arm64ec-w64-mingw32-clang не в PATH. Проверь /opt/llvm-mingw.env"

log "Toolchain: $LLVM_MINGW_PATH"
log "arm64ec-w64-mingw32-clang: $(arm64ec-w64-mingw32-clang --version | head -n1)"

# ---------- 2. источники ----------
if [[ -z "${WINE_SRC:-}" ]]; then
    # Если репа, в которой лежит этот скрипт, сама является wine-репой (есть configure.ac
    # и dlls/ntdll) — используем её. Это как раз кейс форка Proton_arm64.
    if [[ -f "$REPO_ROOT/configure.ac" && -d "$REPO_ROOT/dlls/ntdll" ]]; then
        WINE_SRC="$REPO_ROOT"
        log "Использую исходники из текущего репо: $WINE_SRC"
    else
        WINE_SRC="$REPO_ROOT/wine-src"
        if [[ "${SKIP_CLONE:-0}" != "1" && ! -d "$WINE_SRC/.git" ]]; then
            log "Клонирую $WINE_REPO_URL (branch $WINE_BRANCH) → $WINE_SRC"
            git clone --depth=1 -b "$WINE_BRANCH" "$WINE_REPO_URL" "$WINE_SRC"
        else
            log "Использую существующие исходники: $WINE_SRC"
        fi
    fi
fi
[[ -f "$WINE_SRC/configure.ac" ]] || die "В $WINE_SRC нет configure.ac — это не wine."

# ---------- 3. configure ----------
log "STAGING_DIR = $STAGING_DIR"
log "BUILD_DIR   = $BUILD_DIR"
log "JOBS        = $JOBS"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Если нет configure (часто в git-чекауте), поднимаем его через autogen/autoreconf.
if [[ ! -x "$WINE_SRC/configure" ]]; then
    log "configure не найден, генерирую (autoreconf)..."
    ( cd "$WINE_SRC" && ( [[ -x ./autogen.sh ]] && ./autogen.sh || autoreconf -fi ) )
fi

pushd "$BUILD_DIR" >/dev/null

log "Запускаю configure..."
"$WINE_SRC/configure" \
    --enable-archs=arm64ec,aarch64,i386 \
    --prefix=/usr \
    --with-mingw=clang \
    --disable-tests

# ---------- 4. build ----------
log "make -j$JOBS ..."
make -j"$JOBS"

# ---------- 5. install → staging ----------
log "make install DESTDIR=$STAGING_DIR ..."
rm -rf "$STAGING_DIR"
make install DESTDIR="$STAGING_DIR"

popd >/dev/null

# ---------- 6. sanity ----------
log "Содержимое staging:"
ls -la "$STAGING_DIR/usr/lib/wine" || warn "Нет $STAGING_DIR/usr/lib/wine"

for arch in aarch64-unix aarch64-windows arm64ec-windows i386-windows; do
    if [[ -d "$STAGING_DIR/usr/lib/wine/$arch" ]]; then
        printf '  \033[1;32mOK\033[0m  %s\n' "$arch"
    else
        warn "НЕТ $arch — проверь флаги configure и PATH toolchain."
    fi
done

log "Сборка завершена. Staging: $STAGING_DIR"
