#!/data/data/com.termux/files/usr/bin/bash
# termux-build.sh
# ---------------------------------------------------------------------------
# Сборка Wine ARM64EC (Valve proton_11.0) → .wcp НА ТЕЛЕФОНЕ в Termux.
#
# Зачем proot-distro: чистый Termux использует bionic libc, а toolchain
# llvm-mingw (bylaws) и mingw-w64 собраны под glibc. Поэтому build происходит
# внутри Ubuntu в proot-distro, а Termux играет роль оркестратора.
#
# Workflow:
#   /sdcard/steam/Proton_arm64/  --rsync-->  ~/steam/Proton_arm64/
#                                             |
#                                             v   (bind-mount внутрь proot)
#                                        proot-distro ubuntu
#                                             |
#                                             v
#                                        /sdcard/steam/out/*.wcp
#
# Workflow:
#   - Пользователь редактирует исходники ТОЛЬКО на GitHub (в браузере / IDE).
#   - Локально /sdcard/steam/Proton_arm64/ — это зеркало. Скрипт каждый запуск
#     делает hard reset на origin/proton_11.0, локальные правки ЗАТИРАЮТСЯ.
#   - Первый запуск сам склонирует репу, если её ещё нет.
#
# Использование:
#   pkg install git
#   termux-setup-storage           # разреши доступ к /sdcard
#   # (опционально, первый раз скрипт сам клонирует если нет):
#   # git clone -b proton_11.0 https://github.com/DeriXrace/Proton_arm64.git /sdcard/steam/Proton_arm64
#   bash /sdcard/steam/Proton_arm64/scripts/termux-build.sh
#
# Env-флаги:
#   SKIP_GIT_PULL=1     — не трогать git, строить то что лежит
#   SKIP_DEPS=1         — пропустить apt-get внутри ubuntu
#   SKIP_TOOLCHAIN=1    — пропустить скачивание llvm-mingw
#   SDCARD_DIR=...      — другой путь (default /sdcard/steam)
#   OUTPUT_SDCARD=...   — куда класть .wcp (default $SDCARD_DIR/out)
# ---------------------------------------------------------------------------
set -euo pipefail

# ------------------- config -------------------
SDCARD_DIR="${SDCARD_DIR:-/sdcard/steam}"
WORK_DIR="${WORK_DIR:-$HOME/steam}"
REPO_NAME="${REPO_NAME:-Proton_arm64}"
REPO_BRANCH="${REPO_BRANCH:-proton_11.0}"
REPO_URL="${REPO_URL:-https://github.com/DeriXrace/Proton_arm64.git}"
OUTPUT_SDCARD="${OUTPUT_SDCARD:-$SDCARD_DIR/out}"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

# ------------------- helpers -------------------
C_INFO='\033[1;36m'; C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_OK='\033[1;32m'; C_RST='\033[0m'
log()  { printf "${C_INFO}[termux]${C_RST} %s\n" "$*"; }
ok()   { printf "${C_OK}[termux]${C_RST} %s\n" "$*"; }
warn() { printf "${C_WARN}[termux]${C_RST} %s\n" "$*" >&2; }
die()  { printf "${C_ERR}[termux]${C_RST} %s\n" "$*" >&2; exit 1; }

# ------------------- 0. sanity -------------------
[ -d /data/data/com.termux ] || die "Это не Termux. Скрипт рассчитан на Termux Android ARM64."
[ "$(uname -m)" = "aarch64" ] || warn "uname -m = $(uname -m), ожидается aarch64."

# ВАЖНО: уходим в HOME. Если запускать скрипт из /sdcard/... (FUSE),
# у proot ломается getcwd() и tarball криво распаковывается — получается
# пустой rootfs без /etc. Все последующие команды работают с абсолютными
# путями, так что cd в HOME ни на что не повлияет.
mkdir -p "$HOME"
cd "$HOME"

# storage access
if [ ! -r "$SDCARD_DIR" ] && [ ! -L "$HOME/storage" ]; then
    warn "Нет доступа к /sdcard — запускаю termux-setup-storage."
    warn "Разреши доступ в диалоге Android, потом перезапусти скрипт."
    termux-setup-storage || true
    sleep 2
fi
[ -d "$SDCARD_DIR" ] || die "Нет каталога $SDCARD_DIR. Создай его и положи туда репу: git clone -b $REPO_BRANCH $REPO_URL $SDCARD_DIR/$REPO_NAME"

# ------------------- 1. termux packages -------------------
# SKIP_DEPS=1 пропускает и termux pkg update (он медленный — 100+ репо),
# и apt-get внутри ubuntu. Полезно при повторных запусках.
if [ "${SKIP_DEPS:-0}" != "1" ]; then
    log "Обновляю/ставлю termux-пакеты (git, rsync, proot-distro)..."
    yes | pkg update -y >/dev/null 2>&1 || true
    pkg install -y git rsync proot-distro >/dev/null
else
    log "SKIP_DEPS=1 — пропускаю pkg update/install в termux."
    # Но убедиться что нужные пакеты стоят, всё же надо.
    for p in git rsync proot-distro; do
        command -v "$p" >/dev/null 2>&1 || pkg install -y "$p" >/dev/null
    done
fi

# ------------------- 2. proot-distro ubuntu -------------------
PROOT_ROOTFS="${PREFIX}/var/lib/proot-distro/installed-rootfs/${PROOT_DISTRO}"

# Детект битого rootfs: каталог есть, но /etc нет — значит предыдущая
# установка упала на getcwd() и нужно чистить и ставить заново.
if [ -d "$PROOT_ROOTFS" ] && [ ! -d "$PROOT_ROOTFS/etc" ]; then
    warn "Rootfs $PROOT_DISTRO повреждён (нет /etc). Удаляю и ставлю заново."
    proot-distro remove "$PROOT_DISTRO" 2>/dev/null || true
    rm -rf "$PROOT_ROOTFS"
fi

if [ ! -d "$PROOT_ROOTFS/etc" ]; then
    log "Устанавливаю Ubuntu в proot-distro (~500 МБ, качается один раз)..."
    # cd $HOME — критично для proot getcwd(); см. sanity block выше.
    ( cd "$HOME" && proot-distro install "$PROOT_DISTRO" ) \
        || die "proot-distro install $PROOT_DISTRO упал. Проверь интернет и что не запускал скрипт из /sdcard/..."
else
    log "Ubuntu proot уже установлен: $PROOT_ROOTFS"
fi

# ------------------- 3. git на /sdcard стороне -------------------
# Workflow: пользователь редактирует ТОЛЬКО на GitHub. Локально /sdcard/... —
# это зеркало. Поэтому вместо pull --ff-only делаем fetch + reset --hard, чтобы
# любые локальные расхождения всегда затирались копией с GitHub.
#
# Про `safe.directory`: на /sdcard (FUSE) владелец файлов — не тот uid, под
# которым работает git в Termux. Git с 2.35+ ругается "dubious ownership".
# Разрешаем явно.
SDCARD_REPO="$SDCARD_DIR/$REPO_NAME"
git config --global --add safe.directory "$SDCARD_REPO" 2>/dev/null || true
git config --global --add safe.directory '*'          2>/dev/null || true

if [ "${SKIP_GIT_PULL:-0}" != "1" ]; then
    if [ -d "$SDCARD_REPO/.git" ]; then
        log "Синхронизирую $SDCARD_REPO с origin/$REPO_BRANCH (hard reset, локальные правки затираются)"
        ( cd "$SDCARD_REPO" \
          && git config --local core.fileMode false \
          && git fetch --prune origin "$REPO_BRANCH" \
          && git checkout -B "$REPO_BRANCH" "origin/$REPO_BRANCH" \
          && git reset --hard "origin/$REPO_BRANCH" \
          && git clean -fdx -e 'wine-build/' -e 'wine-staging/' -e 'wine-src/' \
        ) || die "git sync провалился. Проверь интернет и что $SDCARD_REPO — валидный git-репо."
        ok "Синхронизировано с GitHub (branch $REPO_BRANCH)."
    else
        if [ -d "$SDCARD_REPO" ]; then
            warn "$SDCARD_REPO существует, но это не git-репа (.git отсутствует)."
            warn "Переношу старое содержимое в ${SDCARD_REPO}.backup.$$ и клонирую заново."
            mv "$SDCARD_REPO" "${SDCARD_REPO}.backup.$$"
        fi
        log "Клонирую $REPO_URL (branch $REPO_BRANCH) → $SDCARD_REPO ..."
        mkdir -p "$SDCARD_DIR"
        # Клонируем в termux home (быстрее, не через FUSE), потом cp -a на /sdcard.
        TMP_CLONE="$WORK_DIR/.clone-tmp-$$"
        rm -rf "$TMP_CLONE"
        mkdir -p "$WORK_DIR"
        git clone --depth=1 -b "$REPO_BRANCH" "$REPO_URL" "$TMP_CLONE"
        log "Копирую клон в $SDCARD_REPO (это долго, первый раз)..."
        cp -a "$TMP_CLONE" "$SDCARD_REPO"
        rm -rf "$TMP_CLONE"
        ok "Клонировано."
    fi
else
    log "SKIP_GIT_PULL=1 — пропускаю синхронизацию с GitHub."
fi

# ------------------- 4. rsync /sdcard → termux -------------------
mkdir -p "$WORK_DIR/$REPO_NAME"
log "Синхронизация $SDCARD_DIR/$REPO_NAME/  →  $WORK_DIR/$REPO_NAME/"
# --delete чтобы удалённые на /sdcard файлы убирались и в termux.
# Исключаем build-директории (они живут рядом, см. ниже) — на всякий случай.
rsync -a --delete \
    --exclude='/wine-build/' \
    --exclude='/wine-staging/' \
    --exclude='/wine-src/' \
    "$SDCARD_DIR/$REPO_NAME/" "$WORK_DIR/$REPO_NAME/"

# chmod +x — на FUSE /sdcard exec-бит не сохраняется
chmod +x "$WORK_DIR/$REPO_NAME/scripts/"*.sh 2>/dev/null || true

# ------------------- 5. build inside Ubuntu proot -------------------
mkdir -p "$OUTPUT_SDCARD"

# BUILD_DIR / STAGING_DIR вынесены РЯДОМ с репой, а не внутрь — иначе rsync --delete
# на следующем запуске снесёт их.
# Внутри proot termux-home видно по тому же пути (proot-distro его биндит),
# но мы на всякий случай явно биндим в /work.
log "Стартую сборку внутри Ubuntu proot..."
log "  /work       -> $WORK_DIR"
log "  /output     -> $OUTPUT_SDCARD"
log "  SDCARD_DIR  -> $SDCARD_DIR"
log ""
log "ЭТО ЗАЙМЁТ МНОГО ВРЕМЕНИ (часы на телефоне). Держи зарядник в розетке."
log ""

# Пробрасываем флаги SKIP_* внутрь proot.
# cd в HOME — тот же фикс getcwd() для proot login.
cd "$HOME"
proot-distro login "$PROOT_DISTRO" \
    --bind "$WORK_DIR:/work" \
    --bind "$OUTPUT_SDCARD:/output" \
    -- /bin/bash -c "
        set -e
        export SKIP_DEPS='${SKIP_DEPS:-0}'
        export SKIP_TOOLCHAIN='${SKIP_TOOLCHAIN:-0}'
        export BUILD_DIR=/work/wine-build
        export STAGING_DIR=/work/wine-staging
        export OUTPUT_DIR=/output
        export JOBS=\"\${JOBS:-\$(nproc)}\"
        cd /work/${REPO_NAME}
        bash ./scripts/build-all.sh
    "

# ------------------- 6. результат -------------------
log "Сборка завершена."
if ls "$OUTPUT_SDCARD"/*.wcp >/dev/null 2>&1; then
    ok "Готовые .wcp в $OUTPUT_SDCARD/:"
    ls -lh "$OUTPUT_SDCARD"/*.wcp
    ok "Импортируй в WinLator Bionic Ludashi: Contents → Wine → Import."
else
    warn "В $OUTPUT_SDCARD .wcp не найден — посмотри лог сборки выше."
    exit 1
fi
