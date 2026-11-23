#!/usr/bin/env bash
# Встраивает в .app сцены онбординга: страницу `App/Onboarding/app/scene.html` и всё, что она импортирует
# (плеер, перо, сцены). Список файлов не ведётся руками: скрипт идёт по `import … from '…'` от страницы, поэтому
# в бандл попадает ровно то, что нужно сцене, а пропавший импорт ломает сборку здесь же.
# Вызывается фазой сборки Xcode (`App/project.yml`) до подписи бандла.
set -euo pipefail
APP="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$(cd "$ROOT/App/Onboarding" && pwd -P)"
DST="$APP/Contents/Resources/Onboarding"
rm -rf "$DST" && mkdir -p "$DST"

queue=(app/scene.html app/scene.js)
seen=" "
while ((${#queue[@]})); do
  f="${queue[0]}"
  queue=("${queue[@]:1}")
  [[ "$seen" == *" $f "* ]] && continue
  seen+="$f "
  [[ -f "$SRC/$f" ]] || { echo "embed-onboarding: нет файла App/Onboarding/$f" >&2; exit 1; }
  mkdir -p "$DST/$(dirname "$f")"
  cp "$SRC/$f" "$DST/$f"
  [[ "$f" == *.js ]] || continue
  dir="$(dirname "$f")"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    abs="$(cd "$SRC/$dir/$(dirname "$rel")" 2>/dev/null && pwd -P)/$(basename "$rel")" \
      || { echo "embed-onboarding: $f импортирует несуществующий $rel" >&2; exit 1; }
    case "$abs" in
      "$SRC"/*) queue+=("${abs#"$SRC"/}") ;;
      *) echo "embed-onboarding: $f импортирует $rel вне App/Onboarding" >&2; exit 1 ;;
    esac
  done < <(grep -oE "from '[^']+'" "$SRC/$f" | sed -E "s/^from '(.*)'$/\1/")
done
