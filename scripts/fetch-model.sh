#!/usr/bin/env bash
# Модель движка для тестов и стендов без установки приложения: тот же репозиторий, та же ревизия и те же SHA-256,
# что скачивает Installer (App/Sources/Setup/Manifest.swift). Если модель уже поставило приложение, второй раз
# её не качает. Печатает путь к папке модели.
#
#   scripts/fetch-model.sh                         → build/devruntime/model/<ревизия> (~0,7 ГБ)
#   NEKTO_MODEL_DIR=<папка> scripts/fetch-model.sh → в эту папку
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/brand.sh"
source "$ROOT/scripts/model.sh"

DEST="$(model_dir)"
mkdir -p "$DEST"
while read -r path size sha; do
  out="$DEST/$path"
  if [[ -f "$out" && "$(stat -f %z "$out")" == "$size" ]] && echo "$sha  $out" | shasum -a 256 -c --status; then
    continue
  fi
  echo "fetch-model: $path ($((size / 1000000)) МБ)" >&2
  # .part докачивается после обрыва; на место файл встаёт только после сверки SHA-256.
  curl -fL --retry 5 --retry-delay 3 -C - --progress-bar -o "$out.part" \
    "https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REVISION/$path"
  if ! echo "$sha  $out.part" | shasum -a 256 -c --status; then
    rm -f "$out.part"
    echo "fetch-model: SHA-256 не совпал у $path" >&2
    exit 1
  fi
  mv "$out.part" "$out"
done < <(model_files)
echo "$DEST"
