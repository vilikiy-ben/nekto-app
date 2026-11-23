# Имя приложения для скриптов сборки и образа диска. Подключается через `source`.
# В Swift имя записано в App/Sources/App/Brand.swift, в проекте — в App/project.yml;
# что все три места согласны, проверяет scripts/checks/name-audit.py.
APP_NAME="Nekto"
APP_BUNDLE_ID="app.nekto.mac"
# Команда Apple Developer для подписи Developer ID в репозитории не записана: $NEKTO_TEAM_ID, иначе команда
# единственного сертификата «Developer ID Application» в Связке ключей. release.sh, notary-setup.sh.
app_team_id() {
  if [[ -n "${NEKTO_TEAM_ID:-}" ]]; then echo "$NEKTO_TEAM_ID"; return; fi
  local teams
  teams="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"Developer ID Application: .*(\([A-Z0-9]\{10\}\))".*/\1/p' | sort -u)"
  [[ -n "$teams" && "$(grep -c . <<<"$teams")" == 1 ]] && echo "$teams"
  return 0
}
