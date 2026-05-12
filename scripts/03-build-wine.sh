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

# include/wine/vulkan.h, wgl.h, ntsyscalls.h, win32syscalls.h, server_protocol.h
# и пр. помечены в .gitattributes как "generated" — при git clone они могут
# отсутствовать, а configure/makedep падают без них:
#   error: open wine/vulkan.h : No such file or directory
#   error: ntsyscalls.h: No such file or directory
# Регенерируем всё нужное из xml/def/perl источников ДО configure.

# 3a. vulkan.h (+ все vulkan thunks) из dlls/winevulkan/make_vulkan (python3 + vk.xml).
#     make_vulkan генерит сразу: vulkan.h, loader_thunks.c/h, vulkan_thunks.c/h,
#     winevulkan.spec, winevulkan.json, vulkan-1.spec. Если хоть одного из них нет —
#     запускаем. (Один файл мог быть подложен вручную, а остальные — нет.)
VK_OUTS=(
    "$WINE_SRC/include/wine/vulkan.h"
    "$WINE_SRC/dlls/winevulkan/loader_thunks.c"
    "$WINE_SRC/dlls/winevulkan/loader_thunks.h"
    "$WINE_SRC/dlls/winevulkan/vulkan_thunks.c"
    "$WINE_SRC/dlls/winevulkan/vulkan_thunks.h"
    "$WINE_SRC/dlls/winevulkan/winevulkan.spec"
    "$WINE_SRC/dlls/vulkan-1/vulkan-1.spec"
)
VK_MISSING=0
for f in "${VK_OUTS[@]}"; do
    [[ -f "$f" ]] || { VK_MISSING=1; break; }
done
if [[ $VK_MISSING -eq 1 ]]; then
    if [[ -f "$WINE_SRC/dlls/winevulkan/make_vulkan" ]]; then
        log "Генерирую vulkan.h + thunks (python3 ./make_vulkan)..."
        ( cd "$WINE_SRC/dlls/winevulkan" && python3 ./make_vulkan ) \
            || warn "make_vulkan упал — проверь python3 и интернет."
    else
        warn "Нет dlls/winevulkan/make_vulkan — configure упадёт."
    fi
fi

# 3b. ntsyscalls.h + win32syscalls.h из tools/make_specfiles (perl)
if [[ ! -f "$WINE_SRC/dlls/ntdll/ntsyscalls.h" || ! -f "$WINE_SRC/dlls/win32u/win32syscalls.h" ]]; then
    if [[ -f "$WINE_SRC/tools/make_specfiles" ]]; then
        log "Генерирую ntsyscalls.h, win32syscalls.h (perl tools/make_specfiles)..."
        ( cd "$WINE_SRC" && perl ./tools/make_specfiles ) \
            || warn "make_specfiles упал — проверь perl."
    else
        warn "Нет tools/make_specfiles."
    fi
fi

# 3c. server_protocol.h — НЕ перегенерируем.
#     В Valve proton_11.0 этот файл УЖЕ в git с кастомными расширениями
#     (fsync, query_directory_file, и др.). tools/make_requests генерит
#     только upstream-версию без Valve-патчей → ломает сборку.
#     Если файл отсутствует — это критическая ошибка (git clone битый).
if [[ ! -f "$WINE_SRC/include/wine/server_protocol.h" ]]; then
    die "include/wine/server_protocol.h отсутствует! Этот файл должен быть в git. Проверь: git checkout -- include/wine/server_protocol.h"
fi

# 3d. opengl: wgl.h + opengl32 thunks — через dlls/opengl32/make_opengl.
GL_OUTS=(
    "$WINE_SRC/include/wine/wgl.h"
    "$WINE_SRC/dlls/opengl32/thunks.c"
    "$WINE_SRC/dlls/opengl32/unix_thunks.c"
    "$WINE_SRC/dlls/opengl32/opengl32.spec"
)
GL_MISSING=0
for f in "${GL_OUTS[@]}"; do
    [[ -f "$f" ]] || { GL_MISSING=1; break; }
done
if [[ $GL_MISSING -eq 1 && -f "$WINE_SRC/dlls/opengl32/make_opengl" ]]; then
    log "Генерирую wgl.h + opengl thunks (perl ./make_opengl)..."
    ( cd "$WINE_SRC/dlls/opengl32" && perl ./make_opengl ) \
        || warn "make_opengl упал — opengl32 может не собраться."
fi

# 3e. opencl thunks — через dlls/opencl/make_opencl
CL_OUTS=(
    "$WINE_SRC/dlls/opencl/opencl.spec"
    "$WINE_SRC/dlls/opencl/pe_thunks.c"
    "$WINE_SRC/dlls/opencl/unix_thunks.c"
)
CL_MISSING=0
for f in "${CL_OUTS[@]}"; do
    [[ -f "$f" ]] || { CL_MISSING=1; break; }
done
if [[ $CL_MISSING -eq 1 && -f "$WINE_SRC/dlls/opencl/make_opencl" ]]; then
    log "Генерирую opencl thunks (perl ./make_opencl)..."
    ( cd "$WINE_SRC/dlls/opencl" && perl ./make_opencl ) \
        || warn "make_opencl упал."
fi

# 3f. make_unicode требует XML::LibXML + Digest::SHA (perl). Если unicode-файлы
#     отсутствуют, пробуем сгенерить; если не получится — предупреждаем, но
#     часть из них может быть в репе, и make подтянет их сам позже.
if [[ ! -f "$WINE_SRC/dlls/dwrite/bracket.c" ]]; then
    if [[ -f "$WINE_SRC/tools/make_unicode" ]]; then
        log "Генерирую unicode-файлы (perl tools/make_unicode)... может потребовать инет."
        ( cd "$WINE_SRC" && perl ./tools/make_unicode ) \
            || warn "make_unicode упал — если make потом запросит bracket.c/linebreak.c, придётся ставить XML::LibXML."
    fi
fi

# 3g. dsound FIR коэффициенты
if [[ ! -f "$WINE_SRC/dlls/dsound/fir.h" ]]; then
    if [[ -f "$WINE_SRC/dlls/dsound/make_fir" ]]; then
        log "Генерирую dsound/fir.h..."
        ( cd "$WINE_SRC/dlls/dsound" && ./make_fir 2>/dev/null || python3 ./make_fir ) \
            || warn "make_fir упал."
    fi
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
