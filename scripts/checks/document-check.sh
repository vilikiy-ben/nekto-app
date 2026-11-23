#!/usr/bin/env bash
# Проверка вида документа и движка редактора без приложения: App/Sources/Document и холст собираются с маленькой
# программой scripts/checks/document-check/main.swift — JSON туда и обратно, Markdown и ответ нейросети, раскладка таблиц
# (метки и слова не рвутся, ширина листа), полнота отрисовки, мышь и текст, копирование, ⌥, кеш при правке, скорость.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/document-check"
SRC="$ROOT/App/Sources"
mkdir -p "$OUT"
swiftc -swift-version 6 -O -o "$OUT/check" \
  "$SRC/App/Brand.swift" "$SRC/Engine/JSONValue.swift" "$SRC/Library/MappingEntry.swift" "$SRC/Library/Restorer.swift" \
  "$SRC/Design/Theme.swift" "$SRC/Design/Typography.swift" \
  "$SRC"/Document/*.swift "$SRC"/Document/Scene/*.swift "$SRC/Workspace/Canvas/DocumentCanvasView.swift" \
  "$SRC/Workspace/Canvas/DocumentCanvasView+Find.swift" "$SRC/Workspace/Canvas/CanvasOverlays.swift" \
  "$ROOT/scripts/checks/document-check/main.swift"
"$OUT/check" "$@"
