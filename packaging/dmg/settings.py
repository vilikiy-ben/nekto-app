# Настройки dmgbuild для Nekto.dmg. Запускается из scripts/dmg.sh:
#   dmgbuild -s packaging/dmg/settings.py -D app=<Nekto.app> -D assets=packaging/dmg Nekto dist/Nekto.dmg
#
# dmgbuild пишет .DS_Store окна сам, без AppleScript и Finder: сборка не просит доступ к автоматизации
# и одинакова на любом Mac. Геометрия согласована с background.swift (Layout).
import os.path

# defines — словарь из -D; путь к самому файлу dmgbuild не передаёт, поэтому папку оформления тоже через -D.
HERE = defines["assets"]  # noqa: F821
app = defines["app"]  # noqa: F821
app_name = os.path.basename(app)

# Содержимое тома: приложение и ярлык на /Applications. Ярлык называется «Программы» — как папка
# в русской macOS и как в подписи на фоне (имя ярлыка Finder не локализует, показывает как есть).
TARGET = "Программы"
files = [app]
symlinks = {TARGET: "/Applications"}
hide_extensions = [app_name]

# Значок тома — иконка приложения (светлая; у .VolumeIcon.icns нет тёмного варианта).
icon = os.path.join(HERE, "VolumeIcon.icns")

# Фон: background.png + background@2x.png, dmgbuild склеивает их в HiDPI TIFF.
# Finder при картинке-фоне подписывает значки чёрным в любой теме, поэтому фон светлый.
background = os.path.join(HERE, "background.png")

# Окно: 660×400 точек, без панелей; значки 128 pt, подписи 13 pt — как в Finder по умолчанию.
window_rect = ((240, 160), (660, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (180, 176),
    TARGET: (480, 176),
}

# Сжатый образ только для чтения. HFS+: на нём Finder надёжно находит фон по алиасу и на macOS 15.
format = "UDZO"
filesystem = "HFS+"
