#!/usr/bin/env bash
# Среда разработки движка: тот же Python и те же пакеты, что ставит приложение (Installer), плюс pytest и генераторы
# образцов. Нужна test-engine.sh.
#
#   scripts/dev-runtime.sh            → build/devruntime/{python,venv}
#   NEKTO_DEVRUNTIME=<папка> scripts/dev-runtime.sh
#
# Модель отдельно: scripts/fetch-model.sh (или установленная приложением; порядок поиска — scripts/model.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${NEKTO_DEVRUNTIME:-$ROOT/build/devruntime}"
# Версия Python — та же, что в App/Sources/Setup/Manifest.swift (pythonVersion).
PYTHON_VERSION="$(sed -n 's/.*static let pythonVersion = "\(.*\)".*/\1/p' "$ROOT/App/Sources/Setup/Manifest.swift")"
[[ -n "$PYTHON_VERSION" ]] || { echo "dev-runtime: не нашёл pythonVersion в Manifest.swift" >&2; exit 1; }

"$ROOT/scripts/fetch-uv.sh" >/dev/null
UV="$ROOT/vendor/uv"
export UV_PYTHON_INSTALL_DIR="$DEST/python" UV_CACHE_DIR="$DEST/cache" UV_NO_CONFIG=1

"$UV" python install "$PYTHON_VERSION" --no-bin --quiet
"$UV" venv "$DEST/venv" --python "$PYTHON_VERSION" --clear --quiet
"$UV" pip sync "$ROOT/Engine/requirements.lock" --require-hashes --python "$DEST/venv/bin/python" --quiet
"$UV" pip install -r "$ROOT/Engine/requirements-dev.txt" --python "$DEST/venv/bin/python" --quiet
echo "$DEST/venv/bin/python — $("$DEST/venv/bin/python" --version)"
