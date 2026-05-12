#!/usr/bin/env bash
# 02-setup-toolchain.sh
# Скачивает последний релиз llvm-mingw (bylaws) для ARM64 Ubuntu, распаковывает в /opt,
# и экспортирует PATH. llvm-mingw от bylaws — единственный toolchain, который
# умеет в ARM64EC (arm64ec-w64-mingw32-clang).
#
# Результат: пишет путь к toolchain в /opt/llvm-mingw.env  — этот файл подключают
# 03-build-wine.sh и build-all.sh через `source`.
set -euo pipefail

log()  { printf '\033[1;36m[toolchain]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[toolchain]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[toolchain]\033[0m %s\n' "$*" >&2; exit 1; }

REPO="bylaws/llvm-mingw"
INSTALL_DIR="/opt"
ENV_FILE="/opt/llvm-mingw.env"

SUDO=""
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Нужен sudo или запуск от root."
    SUDO="sudo"
fi

# ---------- 1. выбираем asset ----------
# ARM64 хост -> ubuntu-24.04-aarch64 сборка toolchain-а (работает на самом ARM64 хосте
# и собирает PE под aarch64 / arm64ec / i386 / x86_64).
ASSET_FILTER='ucrt-ubuntu-24.04-aarch64.tar.xz'
ASSET_FALLBACK='ucrt-ubuntu-22.04-aarch64.tar.xz'

log "Ищу последний релиз llvm-mingw в github.com/${REPO}..."
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

if ! command -v curl >/dev/null 2>&1; then
    die "curl не установлен. Запусти 01-install-deps.sh сначала."
fi

RELEASE_JSON="$(curl -fsSL "$API_URL" || true)"
if [[ -z "$RELEASE_JSON" ]]; then
    warn "Не удалось прочитать GitHub API, пробую /releases."
    RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=1")"
fi

# Достаём browser_download_url без jq — grep'ом.
pick_url() {
    local filter="$1"
    printf '%s' "$RELEASE_JSON" \
        | grep -oE '"browser_download_url":\s*"[^"]+"' \
        | sed -E 's/.*"(https:[^"]+)".*/\1/' \
        | grep -E "$filter" \
        | head -n1 || true
}

DL_URL="$(pick_url "$ASSET_FILTER")"
if [[ -z "$DL_URL" ]]; then
    warn "Asset $ASSET_FILTER не найден в последнем релизе, пробую fallback $ASSET_FALLBACK"
    DL_URL="$(pick_url "$ASSET_FALLBACK")"
fi
[[ -n "$DL_URL" ]] || die "Не нашёл подходящий aarch64 tar.xz в релизе ${REPO}."

FILENAME="$(basename "$DL_URL")"
log "Выбран asset: $FILENAME"
log "URL: $DL_URL"

# ---------- 2. download ----------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TARBALL="$TMP_DIR/$FILENAME"

log "Скачиваю в $TARBALL ..."
curl -fL --retry 3 --retry-delay 2 -o "$TARBALL" "$DL_URL"

# ---------- 3. extract ----------
log "Распаковываю в $INSTALL_DIR ..."
$SUDO mkdir -p "$INSTALL_DIR"
$SUDO tar -xf "$TARBALL" -C "$INSTALL_DIR"

# Каталог, куда всё распаковалось (llvm-mingw-YYYYMMDD-ucrt-ubuntu-24.04-aarch64)
TOOLCHAIN_DIR="$(ls -1d "$INSTALL_DIR"/llvm-mingw-*ucrt-ubuntu-*-aarch64 2>/dev/null | sort -V | tail -n1)"
[[ -n "$TOOLCHAIN_DIR" && -d "$TOOLCHAIN_DIR" ]] \
    || die "Не нашёл распакованный каталог llvm-mingw-* в $INSTALL_DIR"

log "Toolchain установлен: $TOOLCHAIN_DIR"

# ---------- 4. сохраняем env ----------
$SUDO tee "$ENV_FILE" >/dev/null <<EOF
# Сгенерировано 02-setup-toolchain.sh
# Подключай:  source $ENV_FILE
export LLVM_MINGW_PATH="$TOOLCHAIN_DIR"
# КРИТИЧНО: toolchain должен идти первым, иначе системный ar/clang перебьёт
export PATH="\$LLVM_MINGW_PATH/bin:\$PATH"
EOF
log "Env файл записан: $ENV_FILE"

# ---------- 5. проверка ----------
export PATH="$TOOLCHAIN_DIR/bin:$PATH"

log "Проверка компиляторов:"
for cc in arm64ec-w64-mingw32-clang aarch64-w64-mingw32-clang i686-w64-mingw32-clang x86_64-w64-mingw32-clang; do
    if command -v "$cc" >/dev/null 2>&1; then
        printf '  \033[1;32mOK\033[0m  %-38s %s\n' "$cc" "$("$cc" --version | head -n1)"
    else
        warn "  НЕТ $cc"
    fi
done

log "Готово. Чтобы использовать toolchain в текущей сессии: source $ENV_FILE"
