# Wine ARM64EC (Valve proton_11.0) → .wcp для WinLator Bionic Ludashi

Набор shell-скриптов для сборки Wine от Valve (`ValveSoftware/wine`, ветка
`proton_11.0`) под архитектуру **ARM64EC** и упаковки результата в `.wcp` —
контейнер, который понимает WinLator (Bionic Ludashi и совместимые форки).

FEX сюда **НЕ** входит. Ставим готовый `.wcp` от K11MCH1/Winlator101 отдельно.
DXVK / vkd3d — тоже отдельными `.wcp`.

---

## Требования к хосту

- **ARM64 Linux** (Ubuntu 24.04 рекомендуется).
  Подходит: Snapdragon-ноут, Raspberry Pi 5, ARM64 VPS, ARM64 Docker.
- Прямо в **Termux на Android собрать нельзя** — нет `apt-get` в таком виде и
  нет `mingw-w64`. Делай так:
  ```bash
  pkg install proot-distro
  proot-distro install ubuntu
  proot-distro login ubuntu
  # …дальше уже внутри Ubuntu…
  ```
  Внутри Ubuntu уже клонируй репу и запускай скрипты.
- 8+ GB RAM (или добавь swap), ~20 GB свободного диска.

## Файлы

| Скрипт | Что делает |
|---|---|
| `01-install-deps.sh` | `apt-get install` все системные пакеты |
| `02-setup-toolchain.sh` | Качает последний релиз [`bylaws/llvm-mingw`](https://github.com/bylaws/llvm-mingw) (aarch64 ucrt), кладёт в `/opt`, пишет `/opt/llvm-mingw.env` |
| `03-build-wine.sh` | configure `--enable-archs=arm64ec,aarch64,i386 --with-mingw=clang`, `make`, `make install DESTDIR=/tmp/wine-staging` |
| `04-package-wcp.sh` | пакует staging в `wine-valve-arm64ec-proton11.wcp` (tar.xz) |
| `build-all.sh` | прогоняет всё по порядку с остановкой на первой ошибке |

## Быстрый запуск

```bash
git clone https://github.com/DeriXrace/Proton_arm64.git -b proton_11.0
cd Proton_arm64
chmod +x scripts/*.sh
./scripts/build-all.sh
```

Результат: `/tmp/wine-valve-arm64ec-proton11.wcp`.

## По шагам (если что-то падает)

```bash
./scripts/01-install-deps.sh
./scripts/02-setup-toolchain.sh
source /opt/llvm-mingw.env        # ВАЖНО: toolchain в PATH
./scripts/03-build-wine.sh
./scripts/04-package-wcp.sh
```

## Полезные env-переменные

- `WINE_SRC=/path/to/wine` — использовать готовые исходники (по умолчанию:
  текущий репо, если это wine; иначе клонируется `ValveSoftware/wine`).
- `WINE_BRANCH=proton_11.0` — ветка для `git clone`.
- `BUILD_DIR=$PWD/wine-build` — каталог сборки.
- `STAGING_DIR=/tmp/wine-staging` — DESTDIR для `make install`.
- `JOBS=$(nproc)` — параллелизм `make`.
- `OUTPUT_NAME=wine-valve-arm64ec-proton11.wcp` — имя .wcp.
- `SKIP_DEPS=1 SKIP_TOOLCHAIN=1 ./scripts/build-all.sh` — пропустить готовые шаги.

## Установка в WinLator Bionic Ludashi

1. Перенеси `.wcp` на устройство (например, в `Download`).
2. Открой WinLator Bionic Ludashi.
3. Создай новый контейнер типа **ARM64EC**.
4. **Contents → Wine → Import** → укажи наш `.wcp`.
5. **Contents → FEXCore → Import** → `.wcp` от K11MCH1 (FEXCore-2605+).
6. Запусти контейнер.

## Структура staging после `make install`

```
/tmp/wine-staging/usr/
├── bin/            (wine, wine64, wineserver, wineboot, winecfg, ...)
├── lib/wine/
│   ├── aarch64-unix/        # хостовые .so (Linux ARM64)
│   ├── aarch64-windows/     # нативные ARM64 PE .dll
│   ├── arm64ec-windows/     # ARM64EC .dll — для x86_64 через FEX
│   └── i386-windows/        # 32-bit .dll для WOW64
└── share/wine/
```

Нет папки `arm64ec-windows/` → configure не увидел `arm64ec-w64-mingw32-clang`.
Проверь: `which arm64ec-w64-mingw32-clang` и `source /opt/llvm-mingw.env`.
