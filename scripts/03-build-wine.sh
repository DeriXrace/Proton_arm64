#!/usr/bin/env bash
# 03-build-wine.sh — configure + make Wine ARM64EC
# CRITICAL: arm64ec-w64-mingw32-clang MUST be in PATH before this runs.
# Run 00-verify-toolchain.sh first to confirm.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WINE_SRC="${WINE_SRC:-$REPO_ROOT}"
BUILD_DIR="${BUILD_DIR:-/work/wine-build}"
STAGING_DIR="${STAGING_DIR:-/work/wine-staging}"
JOBS="${JOBS:-6}"

# --- 1. Toolchain ---
[ -f /opt/llvm-mingw.env ] && source /opt/llvm-mingw.env
command -v arm64ec-w64-mingw32-clang >/dev/null 2>&1 \
    || { echo "FATAL: arm64ec-w64-mingw32-clang not in PATH"; exit 1; }
echo "[build] arm64ec clang: $(which arm64ec-w64-mingw32-clang)"

# --- 2. Verify arm64ec compiler actually works (not just exists) ---
echo "int main(){return 0;}" > /tmp/test_arm64ec.c
arm64ec-w64-mingw32-clang /tmp/test_arm64ec.c -o /tmp/test_arm64ec.exe || {
    echo "FATAL: arm64ec-w64-mingw32-clang compile test FAILED"
    echo "PATH: $PATH"
    exit 1
}
echo "[build] arm64ec compile test: OK"
rm -f /tmp/test_arm64ec.c /tmp/test_arm64ec.exe

# --- 3. Clean old build ---
rm -rf "$BUILD_DIR" "$STAGING_DIR"
mkdir -p "$BUILD_DIR"

cd "$WINE_SRC"

# --- 4. Generate all 'generated' headers ---
echo "[build] Generating headers..."
perl ./tools/make_requests
perl ./tools/make_specfiles
( cd dlls/winevulkan && python3 ./make_vulkan )

# Verify critical outputs
grep -q "query_directory_file" include/wine/server_protocol.h \
    || { echo "FATAL: server_protocol.h missing proton extensions"; exit 1; }
[ -f dlls/winevulkan/loader_thunks.c ] \
    || { echo "FATAL: loader_thunks.c not generated"; exit 1; }
[ -f dlls/ntdll/ntsyscalls.h ] \
    || { echo "FATAL: ntsyscalls.h not generated"; exit 1; }
echo "[build] Generated headers: OK"

# --- 5. autoreconf ---
echo "[build] autoreconf..."
chmod +x ./autogen.sh 2>/dev/null || true
( ./autogen.sh || autoreconf -fi ) 2>&1 | tail -3

# --- 6. configure with EXPLICIT CC overrides ---
# This is the critical fix: passing arm64ec_CC= explicitly prevents configure
# from silently dropping arm64ec if it can't find the compiler via AC_CHECK_PROGS.
echo "[build] configure (with explicit CC overrides for arm64ec)..."
cd "$BUILD_DIR"
"$WINE_SRC/configure" \
    --enable-archs=arm64ec,aarch64,i386 \
    --prefix=/usr \
    --with-mingw=clang \
    --disable-tests \
    arm64ec_CC=arm64ec-w64-mingw32-clang \
    arm64ec_CXX=arm64ec-w64-mingw32-clang++ \
    aarch64_CC=aarch64-w64-mingw32-clang \
    aarch64_CXX=aarch64-w64-mingw32-clang++ \
    i386_CC=i686-w64-mingw32-clang \
    i386_CXX=i686-w64-mingw32-clang++ \
    2>&1 | tail -10

# --- 7. Verify configure picked up arm64ec ---
if ! grep -q "arm64ec-w64-mingw32-clang" "$BUILD_DIR/config.log" 2>/dev/null; then
    echo "WARNING: arm64ec not mentioned in config.log"
fi

# --- 8. make ---
echo "[build] make -j$JOBS (this will take hours on phone)..."
make -j"$JOBS"

# --- 9. make install ---
echo "[build] make install DESTDIR=$STAGING_DIR..."
make install DESTDIR="$STAGING_DIR"

# --- 10. VERIFY arm64ec-windows exists ---
echo "[build] === lib/wine contents ==="
ls "$STAGING_DIR/usr/lib/wine/"

if [ ! -d "$STAGING_DIR/usr/lib/wine/arm64ec-windows" ]; then
    echo ""
    echo "FATAL: arm64ec-windows/ MISSING from staging!"
    echo "configure did not build arm64ec DLLs despite toolchain being present."
    echo ""
    echo "Relevant config.log lines:"
    grep -A5 "arm64ec" "$BUILD_DIR/config.log" | head -30
    exit 1
fi

ARM64EC_COUNT=$(ls "$STAGING_DIR/usr/lib/wine/arm64ec-windows" | wc -l)
echo "[build] arm64ec-windows DLLs: $ARM64EC_COUNT files"
echo "[build] BUILD SUCCESSFUL."
