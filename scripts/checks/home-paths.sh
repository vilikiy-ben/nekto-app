#!/usr/bin/env bash
# Собранное приложение или образ не выдаёт машину сборки: ни пути домашней папки, ни имени пользователя.
# Такие пути оставляет в исполняемом файле карта отладки, если сборку не обработал strip (App/project.yml, Release).
#
#   scripts/checks/home-paths.sh build/share/app.noindex/Nekto.app
#
# Ищет в каждом файле байты «$HOME/» и «/Users/<пользователь>/». Чужие домашние папки (uv собран на GitHub,
# в нём пути машины runner) — не наши и не мешают. Код возврата 1, если что-то нашлось.
set -euo pipefail
TARGET="${1:?путь к .app или папке}"
[[ -e "$TARGET" ]] || { echo "home-paths: нет $TARGET" >&2; exit 1; }
found="$(LC_ALL=C grep -rlaF -e "$HOME/" -e "/Users/$(id -un)/" "$TARGET" || true)"
if [[ -n "$found" ]]; then
  echo "✗ путь домашней папки в сборке:" >&2
  while IFS= read -r f; do
    echo "  ${f#"$TARGET/"}: $(LC_ALL=C grep -aoF -e "$HOME/" -e "/Users/$(id -un)/" "$f" | wc -l | tr -d ' ') вхожд." >&2
  done <<<"$found"
  exit 1
fi
echo "home-paths: в $(basename "$TARGET") нет путей домашней папки"
