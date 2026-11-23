#!/usr/bin/env bash
# Тесты движка в той же песочнице без сети, что и в приложении. Среда — scripts/dev-runtime.sh.
# Модель: $NEKTO_MODEL_DIR, иначе установленная приложением, иначе скачанная scripts/fetch-model.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/brand.sh"
source "$ROOT/scripts/model.sh"
PY="${NEKTO_PYTHON:-$ROOT/build/devruntime/venv/bin/python}"
[[ -x "$PY" ]] || { echo "test-engine: нет среды $PY — сначала scripts/dev-runtime.sh" >&2; exit 1; }
NEKTO_MODEL_DIR="$(model_dir)"
export NEKTO_MODEL_DIR
model_complete "$NEKTO_MODEL_DIR" ||
  echo "test-engine: модели нет в $NEKTO_MODEL_DIR, тесты с моделью будут пропущены — scripts/fetch-model.sh" >&2
cd "$ROOT/Engine" && sandbox-exec -f "$ROOT/App/Resources/engine-sandbox.sb" "$PY" -m pytest -q tests "$@"
