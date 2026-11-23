#!/usr/bin/env bash
# Встраивает в .app: движок (исходники Python + lock), uv и лицензии. Вызывается фазой сборки Xcode.
set -euo pipefail
APP="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/fetch-uv.sh" >/dev/null
RES="$APP/Contents/Resources/engine"
rm -rf "$RES" && mkdir -p "$RES" "$APP/Contents/Helpers"
rsync -a --exclude '__pycache__' --exclude '*.pyc' "$ROOT/Engine/nekto_engine" "$RES/"
cp "$ROOT/Engine/run_engine.py" "$ROOT/Engine/requirements.lock" "$RES/"
cp "$ROOT/vendor/uv" "$APP/Contents/Helpers/uv"
# Лицензии: Nekto (Apache-2.0, NOTICE) и встроенного uv (MIT требует прикладывать текст к копии программы).
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/packaging/licenses/uv-LICENSE-MIT.txt" "$APP/Contents/Resources/Licenses/"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$APP/Contents/Helpers/uv"
# Xcode при инкрементальной сборке может не переподписать бандл после этой фазы — подписываем сами.
if [[ "${CONFIGURATION:-Release}" == "Release" ]]; then  # в Debug лежит неподписанная __preview.dylib
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$APP"
fi
