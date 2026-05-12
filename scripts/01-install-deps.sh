#!/usr/bin/env bash
# 01-install-deps.sh
# Устанавливает системные зависимости для сборки Wine (Valve proton_11.0) под ARM64EC
# на ARM64 Ubuntu 24.04 (или совместимом Debian/Ubuntu).
set -euo pipefail

log()  { printf '\033[1;36m[deps]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deps]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[deps]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- sanity checks ----------
ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
    warn "Хост-архитектура: $ARCH (не aarch64). Wine ARM64EC собирается на ARM64 хосте."
    warn "Если ты в Termux на Android — запускай из proot-distro Ubuntu, НЕ из самого Termux."
fi

if ! command -v apt-get >/dev/null 2>&1; then
    die "apt-get не найден. Нужен Debian/Ubuntu. Под Termux используй: pkg install proot-distro && proot-distro install ubuntu"
fi

SUDO=""
if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        die "Скрипт не под root и sudo не установлен."
    fi
fi

export DEBIAN_FRONTEND=noninteractive

log "apt-get update..."
$SUDO apt-get update -y

log "Установка пакетов (build toolchain + Wine deps)..."
$SUDO apt-get install -y --no-install-recommends \
    ca-certificates curl wget xz-utils tar file \
    git build-essential autoconf automake libtool \
    flex bison gperf \
    mingw-w64 clang lld llvm \
    pkg-config python3 python3-pip \
    perl libxml-libxml-perl libdigest-sha-perl \
    libgnutls28-dev libunwind-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    libdbus-1-dev \
    libfontconfig-dev libfreetype-dev \
    libx11-dev libxext-dev libxrandr-dev libxcomposite-dev \
    libxi-dev libxfixes-dev libxcursor-dev libxrender-dev \
    libxinerama-dev libxxf86vm-dev \
    libgl-dev libvulkan-dev \
    libpulse-dev libasound2-dev libsdl2-dev \
    libusb-1.0-0-dev \
    libudev-dev libcups2-dev libkrb5-dev \
    libxkbcommon-dev libxkbregistry-dev \
    libosmesa6-dev

log "Готово. Все зависимости установлены."
