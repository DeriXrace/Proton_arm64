#!/data/data/com.termux/files/usr/bin/bash
# termux-build.sh — полная сборка Wine ARM64EC + упаковка .wcp для WinLator
set -euo pipefail

SDCARD_DIR="${SDCARD_DIR:-/sdcard/steam}"
WORK_DIR="${WORK_DIR:-$HOME/steam}"
REPO_NAME="${REPO_NAME:-Proton_arm64}"
REPO_BRANCH="${REPO_BRANCH:-proton_11.0}"
REPO_URL="${REPO_URL:-https://github.com/DeriXrace/Proton_arm64.git}"
OUTPUT_SDCARD="${OUTPUT_SDCARD:-$SDCARD_DIR/out}"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
JOBS="${JOBS:-6}"

C_INFO='\033[1;36m'; C_OK='\033[1;32m'; C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_RST='\033[0m'
log()  { printf "${C_INFO}[termux]${C_RST} %s\n" "$*"; }
ok()   { printf "${C_OK}[termux]${C_RST} %s\n" "$*"; }
warn() { printf "${C_WARN}[termux]${C_RST} %s\n" "$*" >&2; }
die()  { printf "${C_ERR}[termux]${C_RST} %s\n" "$*" >&2; exit 1; }

# --- 0. Sanity ---
[ -d /data/data/com.termux ] || die "Не Termux."
mkdir -p "$HOME" && cd "$HOME"

# Storage access
if [ ! -r "$SDCARD_DIR" ] && [ ! -L "$HOME/storage" ]; then
    termux-setup-storage || true; sleep 2
fi
[ -d "$SDCARD_DIR" ] || die "Нет $SDCARD_DIR"

# --- 1. Termux packages ---
if [ "${SKIP_DEPS:-0}" != "1" ]; then
    log "pkg update + install..."
    yes | pkg update -y >/dev/null 2>&1 || true
    pkg install -y git rsync proot-distro >/dev/null
else
    for p in git rsync proot-distro; do
        command -v "$p" >/dev/null 2>&1 || pkg install -y "$p" >/dev/null
    done
fi

# --- 2. proot-distro ubuntu ---
PROOT_ROOTFS="${PREFIX}/var/lib/proot-distro/installed-rootfs/${PROOT_DISTRO}"
if [ -d "$PROOT_ROOTFS" ] && [ ! -d "$PROOT_ROOTFS/etc" ]; then
    warn "Битый rootfs — переустанавливаю..."
    proot-distro remove "$PROOT_DISTRO" 2>/dev/null || true
    rm -rf "$PROOT_ROOTFS"
fi
if [ ! -d "$PROOT_ROOTFS/etc" ]; then
    log "Устанавливаю Ubuntu proot (~500 МБ)..."
    ( cd "$HOME" && proot-distro install "$PROOT_DISTRO" ) \
        || die "proot-distro install упал"
fi

# --- 3. Git sync ---
SDCARD_REPO="$SDCARD_DIR/$REPO_NAME"
git config --global --add safe.directory '*' 2>/dev/null || true

if [ "${SKIP_GIT_PULL:-0}" != "1" ]; then
    if [ -d "$SDCARD_REPO/.git" ]; then
        log "git fetch + reset --hard origin/$REPO_BRANCH..."
        ( cd "$SDCARD_REPO" \
          && git config --local core.fileMode false \
          && git fetch --prune origin "$REPO_BRANCH" \
          && git checkout -B "$REPO_BRANCH" "origin/$REPO_BRANCH" \
          && git reset --hard "origin/$REPO_BRANCH" \
          && git clean -fdx -e 'wine-build/' -e 'wine-staging/' \
        ) || die "git sync упал"
        ok "Синхронизировано с GitHub."
    else
        die "$SDCARD_REPO/.git не найден. Клонируй: git clone -b $REPO_BRANCH $REPO_URL $SDCARD_REPO"
    fi
fi

# --- 4. rsync /sdcard → ~/steam ---
mkdir -p "$WORK_DIR/$REPO_NAME"
log "rsync $SDCARD_REPO → $WORK_DIR/$REPO_NAME ..."
rsync -a --delete \
    --exclude='/wine-build/' --exclude='/wine-staging/' \
    "$SDCARD_REPO/" "$WORK_DIR/$REPO_NAME/"
chmod +x "$WORK_DIR/$REPO_NAME/scripts/"*.sh 2>/dev/null || true

# --- 5. Сборка внутри Ubuntu proot ---
mkdir -p "$OUTPUT_SDCARD"
log ""
log "=========================================="
log "  СБОРКА WINE ARM64EC (5-7 часов)"
log "  Держи зарядник. Не трогай Termux."
log "=========================================="
log ""

cd "$HOME"
proot-distro login "$PROOT_DISTRO" \
    --bind "$WORK_DIR:/work" \
    --bind "$OUTPUT_SDCARD:/output" \
    -- /bin/bash -c '
set -e

JOBS='"$JOBS"'

# === Зависимости ===
if [ "${SKIP_DEPS:-0}" != "1" ]; then
    echo "[proot] apt-get update + install..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget xz-utils tar file \
        git build-essential autoconf automake libtool \
        flex bison gperf mingw-w64 clang lld llvm \
        pkg-config python3 perl \
        libgnutls28-dev libunwind-dev \
        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
        libdbus-1-dev libfontconfig-dev libfreetype-dev \
        libx11-dev libxext-dev libxrandr-dev libxcomposite-dev \
        libxi-dev libxfixes-dev libxcursor-dev libxrender-dev \
        libxinerama-dev libxxf86vm-dev libgl-dev libvulkan-dev \
        libpulse-dev libasound2-dev libsdl2-dev \
        libusb-1.0-0-dev libudev-dev libcups2-dev libkrb5-dev \
        libxkbcommon-dev libosmesa6-dev >/dev/null
fi

# === Toolchain ===
if [ -f /opt/llvm-mingw.env ]; then
    source /opt/llvm-mingw.env
fi
if ! command -v arm64ec-w64-mingw32-clang >/dev/null 2>&1; then
    echo "[proot] Скачиваю llvm-mingw..."
    API_URL="https://api.github.com/repos/bylaws/llvm-mingw/releases/latest"
    DL_URL=$(curl -fsSL "$API_URL" | grep -oE "https://[^\"]+ucrt-ubuntu-[0-9.]+-aarch64\\.tar\\.xz" | head -1)
    [ -n "$DL_URL" ] || { echo "ОШИБКА: не нашёл llvm-mingw release"; exit 1; }
    curl -fL -o /tmp/llvm-mingw.tar.xz "$DL_URL"
    tar -xf /tmp/llvm-mingw.tar.xz -C /opt/
    rm -f /tmp/llvm-mingw.tar.xz
    TOOLCHAIN_DIR=$(ls -1d /opt/llvm-mingw-*ucrt-ubuntu-*-aarch64 | sort -V | tail -1)
    cat > /opt/llvm-mingw.env <<EOF2
export LLVM_MINGW_PATH="$TOOLCHAIN_DIR"
export PATH="\$LLVM_MINGW_PATH/bin:\$PATH"
EOF2
    source /opt/llvm-mingw.env
fi
echo "[proot] arm64ec clang: $(which arm64ec-w64-mingw32-clang)"

# === Чистим старый build ===
rm -rf /work/wine-build /work/wine-staging

# === Генерируем generated files ===
cd /work/Proton_arm64
echo "[proot] Генерация generated headers..."
perl ./tools/make_requests
perl ./tools/make_specfiles
( cd dlls/winevulkan && python3 ./make_vulkan )

# Верификация
grep -q "query_directory_file" include/wine/server_protocol.h || { echo "ОШИБКА: server_protocol.h не содержит proton-расширений"; exit 1; }
[ -f dlls/winevulkan/loader_thunks.c ] || { echo "ОШИБКА: loader_thunks.c не сгенерирован"; exit 1; }
[ -f dlls/ntdll/ntsyscalls.h ] || { echo "ОШИБКА: ntsyscalls.h не сгенерирован"; exit 1; }

# === autoreconf ===
echo "[proot] autoreconf..."
chmod +x ./autogen.sh 2>/dev/null || true
( ./autogen.sh || autoreconf -fi ) 2>&1 | tail -3

# === configure ===
echo "[proot] configure..."
mkdir -p /work/wine-build && cd /work/wine-build
/work/Proton_arm64/configure \
    --enable-archs=arm64ec,aarch64,i386 \
    --prefix=/usr \
    --with-mingw=clang \
    --disable-tests 2>&1 | tail -5

# === make ===
echo "[proot] make -j$JOBS (это займёт часы)..."
make -j"$JOBS"

# === make install ===
echo "[proot] make install..."
make install DESTDIR=/work/wine-staging

echo "[proot] === lib/wine ==="
ls /work/wine-staging/usr/lib/wine/

# === Генерация Wine prefix через wineboot ===
echo "[proot] Генерация Wine prefix (wineboot --init)..."
export WINEPREFIX=/tmp/wineprefix
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree=;mshtml="
export WINEDEBUG="-all"
export PATH="/work/wine-staging/usr/bin:$PATH"
export LD_LIBRARY_PATH="/work/wine-staging/usr/lib:${LD_LIBRARY_PATH:-}"

rm -rf "$WINEPREFIX" && mkdir -p "$WINEPREFIX"
timeout 300 wineboot --init 2>&1 | tail -5 || true
wineserver -w 2>/dev/null || true

if [ -d "$WINEPREFIX/drive_c" ]; then
    echo "[proot] Prefix OK: $(du -sh $WINEPREFIX | cut -f1)"
else
    echo "[proot] WARN: wineboot не создал prefix — prefixPack будет пустой"
fi

# === Упаковка .wcp ===
echo "[proot] Упаковка .wcp..."
rm -rf /tmp/repack && mkdir /tmp/repack
cp -a /work/wine-staging/usr/bin /tmp/repack/
cp -a /work/wine-staging/usr/lib /tmp/repack/
cp -a /work/wine-staging/usr/share /tmp/repack/ 2>/dev/null || true
# Удаляем dev-утилиты
rm -f /tmp/repack/bin/widl /tmp/repack/bin/winegcc /tmp/repack/bin/wineg++ \
      /tmp/repack/bin/winebuild /tmp/repack/bin/wmc /tmp/repack/bin/wrc \
      /tmp/repack/bin/winemaker /tmp/repack/bin/winedump \
      /tmp/repack/bin/function_grep.pl /tmp/repack/bin/winecpp
rm -rf /tmp/repack/include

# prefixPack.txz
if [ -d "$WINEPREFIX/drive_c" ]; then
    ( cd "$WINEPREFIX" && XZ_OPT="-T0 -6" tar -cJf /tmp/repack/prefixPack.txz . )
else
    tar -cJf /tmp/repack/prefixPack.txz --files-from=/dev/null
fi

# profile.json
cat > /tmp/repack/profile.json <<EOF
{
  "type": "Proton",
  "versionName": "11.0-arm64ec",
  "versionCode": 1,
  "description": "Proton 11.0 arm64ec - DeriXrace custom build",
  "files": [],
  "wine": {
    "binPath": "bin",
    "libPath": "lib",
    "prefixPack": "prefixPack.txz"
  }
}
EOF

# Упаковка (плоский архив)
cd /tmp/repack
rm -f /output/proton-11.0-arm64ec.wcp
XZ_OPT="-T0 -6" tar -cJf /output/proton-11.0-arm64ec.wcp .

echo ""
echo "=========================================="
echo "  ГОТОВО!"
echo "=========================================="
echo "Размер: $(du -sh /output/proton-11.0-arm64ec.wcp | cut -f1)"
echo "lib/wine:"
ls /tmp/repack/lib/wine/
echo "bin:"
ls /tmp/repack/bin/
echo "prefixPack.txz: $(du -sh /tmp/repack/prefixPack.txz | cut -f1)"
echo ""
echo "Импортируй: /sdcard/steam/out/proton-11.0-arm64ec.wcp"
echo "WinLator → Contents → Proton → Import"
'

# --- 6. Результат ---
log ""
if ls "$OUTPUT_SDCARD"/*.wcp >/dev/null 2>&1; then
    ok "ГОТОВО! .wcp в $OUTPUT_SDCARD/:"
    ls -lh "$OUTPUT_SDCARD"/*.wcp
    ok "WinLator → Contents → Proton → Import"
else
    die ".wcp не создан — смотри лог выше."
fi
