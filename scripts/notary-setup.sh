#!/usr/bin/env bash
# Один раз на Mac, где собираются выпуски: сертификат Developer ID и доступ к нотаризации.
# Ничего не меняет сам, кроме записи пароля в Связку ключей (шаг 2) — говорит, чего не хватает и что сделать.
#
#   scripts/notary-setup.sh                         что уже есть и что осталось
#   scripts/notary-setup.sh --apple-id <почта>      шаг 2: сохранить доступ (спросит пароль приложения)
#   scripts/notary-setup.sh --identity              SHA-1 сертификата для подписи (для release.sh)
#
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/brand.sh"
TEAM_ID="$(app_team_id)"
PROFILE="${NEKTO_NOTARY_PROFILE:-nekto-notary}"

identity() {
  security find-identity -v -p codesigning \
    | awk -v t="($TEAM_ID)\"" '/"Developer ID Application: / && index($0, t) { print $2; exit }'
}

if [[ "${1:-}" == "--identity" ]]; then
  id="$(identity)"; [[ -n "$id" ]] && echo "$id" || exit 1
  exit 0
fi

if [[ "${1:-}" == "--apple-id" ]]; then
  APPLE_ID="${2:?почта Apple ID}"
  [[ -n "$TEAM_ID" ]] || { echo "Сначала сертификат (шаг 1) или NEKTO_TEAM_ID=<Team ID>: по нему notarytool знает команду." >&2; exit 1; }
  [[ -t 0 ]] || { echo "Запустите в Терминале: пароль спрашивается интерактивно и не попадает в историю команд." >&2; exit 1; }
  # Пароль — не от Apple ID, а «пароль приложения»: account.apple.com → Вход и безопасность → Пароли приложений.
  xcrun notarytool store-credentials "$PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM_ID"
  exit 0
fi

ok=1
echo "Команда разработчика: ${TEAM_ID:-не найдена (нет сертификата Developer ID; можно задать NEKTO_TEAM_ID)}"
echo
id="$(identity)"
if [[ -n "$id" ]]; then
  echo "✓ 1. Сертификат: $(security find-identity -v -p codesigning | awk -v h="$id" '$2==h {sub(/^[^"]*"/,""); sub(/"$/,""); print}')"
else
  ok=0
  cat <<EOF
✗ 1. Нет сертификата «Developer ID Application»${TEAM_ID:+ команды $TEAM_ID}.
     Xcode → Настройки (⌘,) → Accounts → войти Apple ID этой команды → Manage Certificates… → «+» →
     Developer ID Application. Сертификат и закрытый ключ лягут в Связку ключей «Вход».
     Сделайте копию: Связка ключей → «Мои сертификаты» → сертификат → Экспортировать (.p12, с паролем).
     Ключ существует только на этом Mac; потеряете — придётся выпускать новый (всего их можно пять).
EOF
fi
echo
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "✓ 2. Доступ к нотаризации: профиль «${PROFILE}» в Связке ключей"
else
  ok=0
  cat <<EOF
✗ 2. Нет доступа к нотаризации.
     а) account.apple.com → Вход и безопасность → Пароли приложений → «+» (имя, например, notarytool).
     б) В Терминале: scripts/notary-setup.sh --apple-id <почта Apple ID команды>
        и вставьте этот пароль. Он хранится в Связке ключей, в скриптах и истории его нет.
     Вместо пароля можно ключ App Store Connect API (Users and Access → Integrations → Team Keys):
        xcrun notarytool store-credentials $PROFILE --key AuthKey_XXXX.p8 --key-id XXXX --issuer <Issuer ID>
EOF
fi
echo
if (( ok )); then echo "Всё готово: scripts/release.sh"; else exit 1; fi
