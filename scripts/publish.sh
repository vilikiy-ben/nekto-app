#!/usr/bin/env bash
# Выпуск на GitHub Releases: образ, zip с приложением и SHA256SUMS.txt под тегом v<версия>-<сборка>.
#
#   scripts/publish.sh                ad-hoc-сборка (build.sh --dmg), без подписи Apple → пре-релиз, файлы *-unsigned
#   scripts/publish.sh --notarized    выпуск release.sh (Developer ID + нотаризация) → обычный релиз
#   scripts/publish.sh … --draft      черновик: виден только тем, у кого есть доступ на запись, — чтобы посмотреть
#   scripts/publish.sh … --dry-run    только файлы и описание в build/publish.noindex/, без тега и GitHub
#
# Выпуск собирается из закоммиченного HEAD, который уже есть на GitHub: тег указывает ровно на тот код, из которого
# собраны файлы. Нужны gh (`gh auth login`) и право на запись в репозиторий.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/brand.sh

die() { echo "publish: $*" >&2; exit 1; }
step() { printf '\n▸ %s\n' "$*"; }

NOTARIZED=0 DRAFT=0 DRY=0
for a in "$@"; do
  case "$a" in
    --notarized) NOTARIZED=1 ;;
    --draft) DRAFT=1 ;;
    --dry-run) DRY=1 ;;
    *) die "неизвестный аргумент $a (есть --notarized, --draft, --dry-run)" ;;
  esac
done

# MARK: Проверки до сборки

command -v gh >/dev/null || die "нет gh — https://cli.github.com"
gh auth status >/dev/null 2>&1 || die "gh не вошёл в GitHub — gh auth login"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "в рабочей копии незакоммиченные правки — выпуск собирается из коммита"
COMMIT="$(git rev-parse HEAD)"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
if (( ! DRY )); then
  git fetch --quiet origin
  git branch -r --contains "$COMMIT" | grep -q . || die "HEAD ${COMMIT:0:7} ещё не на GitHub — сначала git push"
fi

# MARK: Сборка

APP="$ROOT/build/share/app.noindex/$APP_NAME.app"
if (( NOTARIZED )); then
  BUILD="$(git rev-list --count HEAD)"
  DMG="$(ls dist/"$APP_NAME"-*-"$BUILD".dmg 2>/dev/null | head -1)"
  [[ -n "$DMG" ]] || die "нет dist/$APP_NAME-<версия>-$BUILD.dmg — сначала scripts/release.sh"
  APP="$ROOT/build/release.noindex/current/$APP_NAME.app"
  spctl --assess --type open --context context:primary-signature "$DMG" 2>/dev/null || die "Gatekeeper не принимает $DMG"
else
  step "Сборка (ad-hoc, без подписи Apple)"
  scripts/build.sh --dmg
  DMG="dist/$APP_NAME.dmg"
fi
[[ -d "$APP" ]] || die "нет $APP"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
[[ "$BUILD" == "$(git rev-list --count HEAD)" ]] || die "сборка $BUILD собрана не из HEAD ($(git rev-list --count HEAD)) — пересоберите"
codesign --verify --deep --strict "$APP" || die "подпись $APP повреждена"
scripts/checks/home-paths.sh "$APP" >/dev/null || die "в сборке пути домашней папки"
hdiutil verify -quiet "$DMG" || die "образ $DMG повреждён"

TAG="v$VERSION-$BUILD"
NAME="$APP_NAME-$VERSION-$BUILD$( (( NOTARIZED )) || echo -unsigned)"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "тег $TAG уже есть — новый выпуск начинается с нового коммита"
gh release view "$TAG" >/dev/null 2>&1 && die "выпуск $TAG уже есть на GitHub"

# MARK: Файлы выпуска

OUT="$ROOT/build/publish.noindex/$TAG"
rm -rf "$OUT" && mkdir -p "$OUT"
cp "$DMG" "$OUT/$NAME.dmg"
# zip — для тех, кому неудобен образ: ditto не теряет симлинки и права бандла, в отличие от zip -r.
# TZ=UTC: время файла в zip (DOS) пишется по поясу машины, а рядом лежит то же время в UTC — их разница
# выдаёт пояс автора. --norsrc --noextattr: без __MACOSX/._* с com.apple.provenance этого Mac; подпись
# бандла живёт в _CodeSignature и Mach-O, не в атрибутах — после распаковки codesign --verify проходит.
TZ=UTC ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUT/$NAME.zip"
zipinfo -1 "$OUT/$NAME.zip" | grep -q '^__MACOSX/' && die "в zip попали атрибуты macOS (__MACOSX)"
(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
step "Файлы: build/publish.noindex/$TAG"
(cd "$OUT" && ls -lh "$NAME.dmg" "$NAME.zip" | awk '{print "  " $5 "\t" $9}' && sed 's/^/  /' SHA256SUMS.txt)

# MARK: Описание выпуска

# Как открыть приложение без подписи Apple. Шаги и надписи проверены в чистой macOS 27 на образе с карантином,
# как после загрузки браузером: на macOS 15+ «Открыть» в контекстном меню Gatekeeper больше не обходит, разрешение —
# только в Системных настройках, и после кнопки там macOS спрашивает ещё раз.
unsigned_ru() { cat <<EOF

### Сборка без подписи Apple

Приложение подписано ad-hoc, без сертификата разработчика и нотаризации, поэтому при первом запуске macOS его
не откроет. Разрешить запуск нужно один раз:

1. Откройте \`$NAME.dmg\` и перетащите Nekto в «Программы».
2. Запустите Nekto. macOS сообщит, что не может проверить приложение, — нажмите «Готово».
3. Откройте «Системные настройки» → «Конфиденциальность и безопасность». В разделе «Безопасность» у строки
   «Файл «Nekto» заблокирован для защиты Вашего Mac» нажмите «Все равно открыть» — кнопка видна около часа после
   попытки запуска.
4. В появившемся окне ещё раз нажмите «Все равно открыть» и введите пароль администратора Mac.

Или одной командой в Терминале после копирования в «Программы» — тогда шаги 2–4 не нужны:
\`xattr -dr com.apple.quarantine /Applications/Nekto.app\`
EOF
}
unsigned_en() { cat <<EOF

### Not signed by Apple

The app is ad-hoc signed, without a Developer ID certificate or notarization, so macOS blocks it on first launch.
Allow it once: drag Nekto from \`$NAME.dmg\` to Applications and launch it, click *Done*, then open *System Settings*
→ *Privacy & Security*, click *Open Anyway* next to the message that Nekto was blocked, click *Open Anyway* again
in the dialog and enter an administrator password. Or run \`xattr -dr com.apple.quarantine /Applications/Nekto.app\`
after copying.
EOF
}

{
  echo "Nekto $VERSION (сборка $BUILD) · коммит [\`${COMMIT:0:7}\`](https://github.com/$REPO/commit/$COMMIT)"
  echo
  echo "Mac с процессором Apple (M1 или новее), macOS 15 или новее. При первом запуске приложение скачает Python"
  echo "и модель (около 0,8 ГБ) — дальше всё работает без интернета. Как пользоваться — [README](https://github.com/$REPO#readme)."
  (( NOTARIZED )) || unsigned_ru
  echo
  echo "### Проверка файлов"
  echo
  echo "Скачайте файлы и \`SHA256SUMS.txt\` в одну папку и выполните в ней \`shasum -a 256 -c SHA256SUMS.txt\`:"
  echo
  echo '```'
  cat "$OUT/SHA256SUMS.txt"
  echo '```'
  echo
  echo "---"
  echo
  echo "**English.** Nekto $VERSION (build $BUILD) for Apple silicon Macs, macOS 15 or later."
  (( NOTARIZED )) || unsigned_en
} > "$OUT/notes.md"

(( DRY )) && { step "Проверка без публикации: описание — build/publish.noindex/$TAG/notes.md"; exit 0; }

# MARK: Тег и выпуск

step "Тег $TAG → ${COMMIT:0:7}"
# Время в теге — в UTC, как у коммитов: пояс машины выпуска выдаёт, где живёт автор.
TZ=UTC git tag -a "$TAG" -m "$APP_NAME $VERSION ($BUILD)" "$COMMIT"
git push --quiet origin "refs/tags/$TAG" || { git tag -d "$TAG" >/dev/null; die "тег не ушёл на GitHub"; }

step "Выпуск на GitHub"
flags=(--verify-tag --title "$APP_NAME $VERSION ($BUILD)$( (( NOTARIZED )) || echo ' — без подписи Apple')"
       --notes-file "$OUT/notes.md")
(( NOTARIZED )) || flags+=(--prerelease)
(( DRAFT )) && flags+=(--draft)
gh release create "$TAG" "$OUT/$NAME.dmg" "$OUT/$NAME.zip" "$OUT/SHA256SUMS.txt" "${flags[@]}"
