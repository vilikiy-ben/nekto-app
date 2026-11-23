#!/usr/bin/env bash
# Release-сборка: build/share/app.noindex/Nekto.app (+ dist/Nekto.dmg при --dmg).
# Продукты сборки лежат в папках .noindex: Spotlight их не индексирует, и в поиске остаётся одна Nekto —
# установленная в «Программы».
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/brand.sh
./scripts/fetch-uv.sh >/dev/null
(cd App && xcodegen generate --quiet)
mkdir -p build
# Номер сборки — число коммитов: растёт сам, у каждого выпуска свой, по нему видно, у кого какая версия.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
xcodebuild -project "App/$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath build/DerivedData.noindex CURRENT_PROJECT_VERSION="$BUILD" build > build/xcodebuild.log 2>&1 || { grep -E "error:" build/xcodebuild.log | head -20; exit 1; }
SRC="build/DerivedData.noindex/Build/Products/Release/$APP_NAME.app"
APP="build/share/app.noindex/$APP_NAME.app"
[[ -d "$SRC" ]] || { echo "сборка не удалась"; exit 1; }
mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
ditto "$SRC" "$APP"
touch "$APP"   # новое время изменения — иначе кеш иконок macOS покажет старую
codesign --verify --deep --strict "$APP"
scripts/checks/home-paths.sh "$APP" >/dev/null
# Xcode регистрирует собранное приложение в LaunchServices — иначе копия из DerivedData всплывает в «Открыть в программе».
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$SRC" "$APP" 2>/dev/null || true
echo "$APP готово"
if [[ "${1:-}" == "--dmg" ]]; then
  ./scripts/dmg.sh "$APP" "dist/$APP_NAME.dmg"
fi
