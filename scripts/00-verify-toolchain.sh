#!/usr/bin/env bash
# 00-verify-toolchain.sh — Verify all 4 cross-compilers work before build
set -euo pipefail

ERRORS=0

check_compiler() {
    local name="$1" cc="$2"
    local testfile="/tmp/test_${name}.c"
    local outfile="/tmp/test_${name}.exe"

    if ! command -v "$cc" >/dev/null 2>&1; then
        echo "FAIL: $cc NOT FOUND in PATH"
        echo "  PATH=$PATH"
        ERRORS=$((ERRORS + 1))
        return
    fi

    echo "int main(){return 0;}" > "$testfile"
    if "$cc" "$testfile" -o "$outfile" 2>/dev/null; then
        echo "  OK: $name ($cc)"
        rm -f "$testfile" "$outfile"
    else
        echo "FAIL: $cc found but compile test FAILED"
        echo "  Location: $(which "$cc")"
        "$cc" "$testfile" -o "$outfile" 2>&1 | head -5 || true
        ERRORS=$((ERRORS + 1))
        rm -f "$testfile" "$outfile"
    fi
}

echo "[verify] Checking cross-compilers..."
echo "[verify] PATH: $PATH"
echo ""

check_compiler "arm64ec"  "arm64ec-w64-mingw32-clang"
check_compiler "aarch64"  "aarch64-w64-mingw32-clang"
check_compiler "i386"     "i686-w64-mingw32-clang"
check_compiler "x86_64"   "x86_64-w64-mingw32-clang"

echo ""
if [ "$ERRORS" -gt 0 ]; then
    echo "FATAL: $ERRORS compiler(s) failed. Cannot build Wine ARM64EC."
    echo ""
    echo "Fix: source /opt/llvm-mingw.env (or run 02-setup-toolchain.sh)"
    echo "  Expected: bylaws/llvm-mingw in /opt/llvm-mingw-*/"
    exit 1
fi

echo "[verify] All 4 cross-compilers OK."
