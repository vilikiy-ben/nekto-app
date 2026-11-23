#!/usr/bin/env bash
# Скачивает закреплённую версию uv (менеджер Python-окружений) и проверяет SHA-256.
# uv встраивается в приложение и на первом запуске ставит Python и зависимости движка.
set -euo pipefail
UV_VERSION="0.13.7"
UV_SHA256="81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/uv"
if [[ -x "$DEST" ]] && "$DEST" --version | grep -q "$UV_VERSION"; then
  echo "uv $UV_VERSION уже на месте"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-aarch64-apple-darwin.tar.gz" -o "$TMP/uv.tgz"
echo "${UV_SHA256}  $TMP/uv.tgz" | shasum -a 256 -c -
tar -xzf "$TMP/uv.tgz" -C "$TMP"
mkdir -p "$ROOT/vendor"
cp "$TMP/uv-aarch64-apple-darwin/uv" "$DEST"
chmod +x "$DEST"
"$DEST" --version
