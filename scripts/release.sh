#!/usr/bin/env bash
# Выпуск для раздачи: Developer ID + нотаризация Apple → dist/Nekto.dmg, который открывается на любом Mac
# без «Всё равно открыть» и без отключения защит. Первый раз — scripts/notary-setup.sh (сертификат и доступ к нотаризации).
#
#   scripts/release.sh               сборка → подпись → нотаризация приложения → образ → нотаризация образа
#   scripts/release.sh --skip-build  то же из уже собранного build/share/app.noindex/Nekto.app
#   scripts/release.sh --resume      продолжить прерванный выпуск: дождаться уже отправленной заявки, а не слать новую
#                                    (первые заявки новой команды Apple может проверять часами)
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/brand.sh
TEAM_ID="$(app_team_id)"
PROFILE="${NEKTO_NOTARY_PROFILE:-nekto-notary}"
WORK="$ROOT/build/release.noindex/current"
ENTITLEMENTS="$ROOT/App/$APP_NAME.entitlements"

die() { echo "release: $*" >&2; exit 1; }
step() { printf '\n▸ %s\n' "$*"; }

# MARK: Проверки до сборки — чтобы не ждать пять минут ради отказа в конце

IDENTITY="${NEKTO_SIGN_IDENTITY:-$(scripts/notary-setup.sh --identity 2>/dev/null || true)}"
[[ -n "$IDENTITY" ]] || die "нет сертификата Developer ID Application${TEAM_ID:+ команды $TEAM_ID} — запустите scripts/notary-setup.sh"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || die "нет доступа к нотаризации (профиль «${PROFILE}» в Связке ключей) — запустите scripts/notary-setup.sh"
[[ -z "$(git status --porcelain 2>/dev/null)" ]] || echo "release: в рабочей копии есть незакоммиченные правки — выпуск соберётся с ними"

MODE="${1:-}"
APP="$WORK/$APP_NAME.app"
if [[ "$MODE" == "--resume" ]]; then
  [[ -d "$APP" ]] || die "нечего продолжать: нет $APP"
  codesign --verify --deep --strict "$APP" 2>/dev/null || die "подпись $APP повреждена — нужен новый выпуск"
  BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
  VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
  step "Продолжаю выпуск $VERSION ($BUILD)"
else

# MARK: Сборка

if [[ "$MODE" != "--skip-build" ]]; then
  step "Сборка"
  scripts/build.sh
fi
SRC="$ROOT/build/share/app.noindex/$APP_NAME.app"
[[ -d "$SRC" ]] || die "нет $SRC"
rm -rf "$WORK" && mkdir -p "$WORK"
ditto "$SRC" "$APP"

# Номер сборки (число коммитов) ставит build.sh.
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"

# MARK: Подпись Developer ID, изнутри наружу

step "Подпись: $(security find-identity -v -p codesigning | awk -v h="$IDENTITY" '$2==h {sub(/^[^"]*"/,""); sub(/"$/,""); print}')"
xattr -cr "$APP"   # Finder-метки и прочие атрибуты ломают подпись ресурсов
# Любой Mach-O внутри, кроме главного, подписывается отдельно: нотаризация отклоняет приложение
# с неподписанным или ad-hoc вложенным кодом. Сейчас это только Helpers/uv — но новый не потеряется.
MAIN="$APP/Contents/MacOS/$APP_NAME"
while IFS= read -r -d '' f; do
  [[ "$f" == "$MAIN" ]] && continue
  file -b "$f" | grep -q '^Mach-O' || continue
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$f"
  echo "  ${f#"$APP/"}"
done < <(find "$APP/Contents" -type f -perm +111 -print0)
codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q get-task-allow \
  && die "в подписи get-task-allow — нотаризация такую сборку не примет"
fi

# MARK: Нотаризация

# notarize <файл> — отправляет, ждёт решения, сохраняет отчёт рядом. Отказ — с перечнем причин из отчёта.
# Номер заявки и SHA-256 отправленного файла пишутся в notary-<имя>.id: если ожидание прервалось, --resume ждёт ту же
# заявку. Новая заявка на тот же файл встала бы в конец очереди.
notarize() {
  local file="$1" name; name="$(basename "$1")"
  local idfile="$WORK/notary-$name.id" sum id="" status
  sum="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [[ -f "$idfile" && "$(sed -n 2p "$idfile")" == "$sum" ]]; then
    id="$(sed -n 1p "$idfile")"
    echo "  $name уже отправлен (id $id), жду решения"
  else
    echo "  отправляю $name ($(du -h "$file" | cut -f1 | tr -d ' ')), обычно 1–5 минут"
    id="$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --output-format json \
      | plutil -extract id raw -o - - 2>/dev/null || true)"
    [[ -n "$id" ]] || die "нотаризация не приняла $name"
    printf '%s\n%s\n' "$id" "$sum" > "$idfile"
  fi
  xcrun notarytool wait "$id" --keychain-profile "$PROFILE" --timeout "${NEKTO_NOTARY_TIMEOUT:-1h}" >/dev/null 2>&1 || true
  status="$(xcrun notarytool info "$id" --keychain-profile "$PROFILE" --output-format json \
    | plutil -extract status raw -o - - 2>/dev/null || true)"
  case "$status" in
    Accepted) ;;
    "In Progress"|"")
      die "Apple ещё проверяет $name (id $id). Первые заявки новой команды бывают долгими; позже: scripts/release.sh --resume" ;;
    *)
      xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$WORK/notary-$name.log.json" >/dev/null 2>&1 || true
      cat "$WORK/notary-$name.log.json" >&2 2>/dev/null || true
      rm -f "$idfile"
      die "нотаризация $name: $status (id $id)" ;;
  esac
  xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$WORK/notary-$name.log.json" >/dev/null 2>&1 || true
  echo "  $name: Accepted (id $id)"
}

step "Нотаризация приложения"
# Если билет уже вшит (продолжение после образа), второй раз приложение не отправляется.
if ! xcrun stapler validate -q "$APP" 2>/dev/null; then
  [[ -f "$WORK/$APP_NAME.zip" ]] || ditto -c -k --keepParent "$APP" "$WORK/$APP_NAME.zip"
  notarize "$WORK/$APP_NAME.zip"
  # Билет — внутрь приложения: так Gatekeeper проверит его и без интернета, уже после копирования из образа.
  xcrun stapler staple -q "$APP"
  xcrun stapler validate -q "$APP"
fi

step "Образ диска"
DMG="$WORK/$APP_NAME.dmg"
if [[ ! -f "$WORK/notary-$APP_NAME.dmg.id" || ! -f "$DMG" ]]; then
  scripts/dmg.sh "$APP" "$DMG" >/dev/null
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
notarize "$DMG"
xcrun stapler staple -q "$DMG"
xcrun stapler validate -q "$DMG"

# MARK: Проверка глазами Gatekeeper

step "Проверка"
spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/  /'
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'
spctl --assess --type execute "$APP" 2>/dev/null || die "Gatekeeper не принимает приложение"
spctl --assess --type open --context context:primary-signature "$DMG" 2>/dev/null || die "Gatekeeper не принимает образ"

mkdir -p dist
cp "$DMG" "dist/$APP_NAME.dmg"
cp "$DMG" "dist/$APP_NAME-$VERSION-$BUILD.dmg"
(cd dist && shasum -a 256 "$APP_NAME-$VERSION-$BUILD.dmg" > "$APP_NAME-$VERSION-$BUILD.dmg.sha256")
step "Готово: dist/$APP_NAME-$VERSION-$BUILD.dmg ($(du -h "$DMG" | cut -f1)), версия $VERSION ($BUILD)"
echo "  SHA-256: $(cut -d' ' -f1 "dist/$APP_NAME-$VERSION-$BUILD.dmg.sha256")"
echo "  Можно отправлять как угодно: мессенджер, почта, общий диск. Получателю нужно только открыть образ и перетащить Nekto в «Программы»"
