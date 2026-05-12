#!/usr/bin/env bash
# 03-build-wine.sh — configure + make Wine ARM64EC
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WINE_SRC="${WINE_SRC:-$REPO_ROOT}"
BUILD_DIR="${BUILD_DIR:-/work/wine-build}"
STAGING_DIR="${STAGING_DIR:-/work/wine-staging}"
JOBS="${JOBS:-6}"

# Toolchain
[ -f /opt/llvm-mingw.env ] && source /opt/llvm-mingw.env
command -v arm64ec-w64-mingw32-clang >/dev/null 2>&1 \
    || { echo "ОШИБКА: arm64ec-w64-mingw32-clang не в PATH"; exit 1; }
echo "[build] arm64ec clang: $(which arm64ec-w64-mingw32-clang)"

# Чистим
rm -rf "$BUILD_DIR" "$STAGING_DIR"
mkdir -p "$BUILD_DIR"

cd "$WINE_SRC"

# Генерация generated files
echo "[build] Генерация headers..."
perl ./tools/make_requests
perl ./tools/make_specfiles
( cd dlls/winevulkan && python3 ./make_vulkan )

# Верификация
grep -q "query_directory_file" include/wine/server_protocol.h \
    || { echo "ОШИБКА: server_protocol.h без proton-расширений"; exit 1; }
[ -f dlls/winevulkan/loader_thunks.c ] \
    || { echo "ОШИБКА: loader_thunks.c не создан"; exit 1; }
[ -f dlls/ntdll/ntsyscalls.h ] \
    || { echo "ОШИБКА: ntsyscalls.h не создан"; exit 1; }

# autoreconf
echo "[build] autoreconf..."
chmod +x ./autogen.sh 2>/dev/null || true
( ./autogen.sh || autoreconf -fi ) 2>&1 | tail -3

# configure
echo "[build] configure..."
cd "$BUILD_DIR"
"$WINE_SRC/configure" \
    --enable-archs=arm64ec,aarch64,i386 \
    --prefix=/usr \
    --with-mingw=clang \
    --disable-tests 2>&1 | tail -5

# make
echo "[build] make -j$JOBS (это займёт часы на телефоне)..."
make -j"$JOBS"

# install
echo "[build] make install DESTDIR=$STAGING_DIR..."
make install DESTDIR="$STAGING_DIR"

echo "[build] === lib/wine ==="
ls "$STAGING_DIR/usr/lib/wine/"
echo "[build] Сборка завершена."
