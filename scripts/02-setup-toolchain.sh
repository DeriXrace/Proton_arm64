#!/usr/bin/env bash
# 02-setup-toolchain.sh — скачивает bylaws/llvm-mingw (arm64ec toolchain)
set -euo pipefail

ENV_FILE="/opt/llvm-mingw.env"

# Если уже установлен — пропускаем
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    if command -v arm64ec-w64-mingw32-clang >/dev/null 2>&1; then
        echo "[toolchain] Уже установлен: $(which arm64ec-w64-mingw32-clang)"
        exit 0
    fi
fi

echo "[toolchain] Скачиваю llvm-mingw (bylaws)..."
API_URL="https://api.github.com/repos/bylaws/llvm-mingw/releases/latest"
DL_URL=$(curl -fsSL "$API_URL" | grep -oE '"browser_download_url":\s*"[^"]+"' | sed 's/.*"\(https[^"]*\)".*/\1/' | grep 'ucrt-ubuntu.*aarch64\.tar\.xz' | head -1)
[ -n "$DL_URL" ] || { echo "ОШИБКА: не нашёл llvm-mingw asset"; exit 1; }

echo "[toolchain] URL: $DL_URL"
curl -fL --retry 3 -o /tmp/llvm-mingw.tar.xz "$DL_URL"
tar -xf /tmp/llvm-mingw.tar.xz -C /opt/
rm -f /tmp/llvm-mingw.tar.xz

TOOLCHAIN_DIR=$(ls -1d /opt/llvm-mingw-*ucrt-ubuntu-*-aarch64 2>/dev/null | sort -V | tail -1)
[ -d "$TOOLCHAIN_DIR" ] || { echo "ОШИБКА: не нашёл распакованный каталог"; exit 1; }

cat > "$ENV_FILE" <<EOF
export LLVM_MINGW_PATH="$TOOLCHAIN_DIR"
export PATH="\$LLVM_MINGW_PATH/bin:\$PATH"
EOF

source "$ENV_FILE"
echo "[toolchain] OK: $(arm64ec-w64-mingw32-clang --version | head -1)"
