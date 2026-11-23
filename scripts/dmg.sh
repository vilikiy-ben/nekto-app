#!/usr/bin/env bash
# Установочный образ: scripts/dmg.sh <Nekto.app> [dist/Nekto.dmg]
# Окно с фоном (стрелка к «Программам»), значок тома — иконка приложения. Оформление — packaging/dmg/
# (фон рисует packaging/dmg/background.swift). dmgbuild закреплён по версии и запускается
# через закреплённый uv из vendor/ — в системный Python ничего не ставится.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/brand.sh"
DMGBUILD_VERSION="1.6.5"
APP="${1:?путь к Nekto.app}"
OUT="${2:-$ROOT/dist/$APP_NAME.dmg}"
[[ -d "$APP" ]] || { echo "нет $APP"; exit 1; }

"$ROOT/scripts/fetch-uv.sh" >/dev/null
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
"$ROOT/vendor/uv" tool run --quiet --python 3.12 --from "dmgbuild==$DMGBUILD_VERSION" \
  dmgbuild -s "$ROOT/packaging/dmg/settings.py" -D app="$APP" -D assets="$ROOT/packaging/dmg" "$APP_NAME" "$OUT"
hdiutil verify -quiet "$OUT"
echo "$OUT: $(du -h "$OUT" | cut -f1)"
