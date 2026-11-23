# Модель движка для скриптов разработки. Подключается через `source` после brand.sh, нужен $ROOT.
# Репозиторий, ревизия, папка и SHA-256 файлов записаны в одном месте — App/Sources/Setup/Manifest.swift,
# отсюда они только читаются: смена модели в приложении сразу меняет её и для тестов.
MANIFEST="$ROOT/App/Sources/Setup/Manifest.swift"
manifest_value() { sed -n "s/.*static let $1 = \"\(.*\)\".*/\1/p" "$MANIFEST"; }
MODEL_REPO="$(manifest_value modelRepo)"
MODEL_REVISION="$(manifest_value modelRevision)"
MODEL_FOLDER="$(manifest_value modelFolder)"
[[ -n "$MODEL_REPO" && -n "$MODEL_REVISION" && -n "$MODEL_FOLDER" ]] || { echo "model.sh: не разобрал модель в $MANIFEST" >&2; exit 1; }

# Файлы модели: «путь размер sha256» по строке.
model_files() {
  sed -n 's/.*\.init(path: "\([^"]*\)", size: \([0-9_]*\), sha256: "\([0-9a-f]*\)").*/\1 \2 \3/p' "$MANIFEST" | tr -d _
}

# Все файлы на месте и нужного размера (SHA-256 сверяет fetch-model.sh при загрузке).
model_complete() {
  local path size _sha
  while read -r path size _sha; do
    [[ -f "$1/$path" && "$(stat -f %z "$1/$path")" == "$size" ]] || return 1
  done < <(model_files)
}

# Где модель: $NEKTO_MODEL_DIR, иначе установленная приложением, иначе скачанная fetch-model.sh.
model_dir() {
  local installed="$HOME/Library/Application Support/$APP_NAME/model/$MODEL_FOLDER"
  if [[ -n "${NEKTO_MODEL_DIR:-}" ]]; then echo "$NEKTO_MODEL_DIR"
  elif model_complete "$installed"; then echo "$installed"
  else echo "$ROOT/build/devruntime/model/$MODEL_FOLDER"
  fi
}
