#!/data/data/com.termux/files/usr/bin/bash
# termux-build.sh — Full Wine ARM64EC build + .wcp packaging for WinLator
# One command: bash /sdcard/steam/Proton_arm64/scripts/termux-build.sh
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
[ -d /data/data/com.termux ] || die "Not Termux."
mkdir -p "$HOME" && cd "$HOME"

if [ ! -r "$SDCARD_DIR" ] && [ ! -L "$HOME/storage" ]; then
    termux-setup-storage || true; sleep 2
fi
[ -d "$SDCARD_DIR" ] || die "No $SDCARD_DIR"

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
    warn "Broken rootfs — reinstalling..."
    proot-distro remove "$PROOT_DISTRO" 2>/dev/null || true
    rm -rf "$PROOT_ROOTFS"
fi
if [ ! -d "$PROOT_ROOTFS/etc" ]; then
    log "Installing Ubuntu proot (~500 MB)..."
    ( cd "$HOME" && proot-distro install "$PROOT_DISTRO" ) || die "proot-distro install failed"
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
        ) || die "git sync failed"
        ok "Synced with GitHub."
    else
        die "$SDCARD_REPO/.git not found. Clone first: git clone -b $REPO_BRANCH $REPO_URL $SDCARD_REPO"
    fi
fi

# --- 4. rsync /sdcard → ~/steam ---
mkdir -p "$WORK_DIR/$REPO_NAME"
log "rsync $SDCARD_REPO → $WORK_DIR/$REPO_NAME ..."
rsync -a --delete \
    --exclude='/wine-build/' --exclude='/wine-staging/' \
    "$SDCARD_REPO/" "$WORK_DIR/$REPO_NAME/"
chmod +x "$WORK_DIR/$REPO_NAME/scripts/"*.sh 2>/dev/null || true

# --- 5. Build inside Ubuntu proot ---
mkdir -p "$OUTPUT_SDCARD"
log ""
log "=========================================="
log "  WINE ARM64EC BUILD (5-7 hours on phone)"
log "  Keep charger connected. Don't touch."
log "=========================================="
log ""

cd "$HOME"
proot-distro login "$PROOT_DISTRO" \
    --bind "$WORK_DIR:/work" \
    --bind "$OUTPUT_SDCARD:/output" \
    -- /bin/bash -c '
set -e
JOBS='"$JOBS"'
export JOBS

# === Dependencies ===
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
    echo "[proot] Dependencies installed."
fi

# === Toolchain (bylaws/llvm-mingw) ===
if [ -f /opt/llvm-mingw.env ]; then
    source /opt/llvm-mingw.env
fi
if ! command -v arm64ec-w64-mingw32-clang >/dev/null 2>&1; then
    echo "[proot] Downloading llvm-mingw..."
    API_URL="https://api.github.com/repos/bylaws/llvm-mingw/releases/latest"
    DL_URL=$(curl -fsSL "$API_URL" | grep -oE "https://[^\"]+ucrt-ubuntu-[0-9.]+-aarch64\\.tar\\.xz" | head -1)
    [ -n "$DL_URL" ] || { echo "FATAL: cannot find llvm-mingw release"; exit 1; }
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

# === Verify toolchain ===
cd /work/Proton_arm64
bash ./scripts/00-verify-toolchain.sh

# === Build Wine ===
bash ./scripts/03-build-wine.sh

# === Package .wcp ===
bash ./scripts/04-package-wcp.sh

echo ""
echo "[proot] ALL DONE."
'

# --- 6. Result ---
log ""
if ls "$OUTPUT_SDCARD"/proton-*.wcp >/dev/null 2>&1; then
    ok "DONE! .wcp files in $OUTPUT_SDCARD/:"
    ls -lh "$OUTPUT_SDCARD"/proton-*.wcp
    ok "Install: WinLator → Contents → Proton → Import"
else
    die ".wcp not created — check log above."
fi
