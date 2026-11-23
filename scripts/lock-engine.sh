#!/usr/bin/env bash
# Пересобирает Engine/requirements.lock: точные версии + SHA-256 хеши для macOS arm64 / Python 3.11.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/fetch-uv.sh" >/dev/null
EXCLUDE_NEWER="2026-11-06T00:00:00Z"   # защита от свежих (непроверенных) релизов
MACOSX_DEPLOYMENT_TARGET=15.0 "$ROOT/vendor/uv" pip compile "$ROOT/Engine/requirements.in" \
  --python-version 3.11 --python-platform aarch64-apple-darwin \
  --generate-hashes --exclude-newer "$EXCLUDE_NEWER" --no-header --quiet \
  -o "$ROOT/Engine/requirements.lock"
echo "lock: $(grep -c '==' "$ROOT/Engine/requirements.lock") пакетов"
