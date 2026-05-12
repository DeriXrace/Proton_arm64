#!/usr/bin/env bash
# 01-install-deps.sh — apt зависимости для сборки Wine ARM64EC
set -euo pipefail
echo "[deps] apt-get update + install..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends \
    ca-certificates curl wget xz-utils tar file \
    git build-essential autoconf automake libtool \
    flex bison gperf mingw-w64 \
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
echo "[deps] Готово."
