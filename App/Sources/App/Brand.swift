import Foundation

/// Имя приложения — в одном месте. Всё, что показывает имя человеку или кладёт его на диск, берёт его отсюда.
///
/// Вне Swift имя записано ещё дважды: `App/project.yml` (цель, продукт, идентификатор бандла) и `scripts/brand.sh`
/// (сборка, образ диска). Что все три места согласны, проверяет `scripts/checks/name-audit.py`.
enum Brand {
    static let name = "Nekto"
    static let bundleID = "app.nekto.mac"
    /// Скрытая папка истории внутри рабочей папки.
    static let historyFolder = ".nekto"

    /// Ключ настройки или аргумент запуска с именем приложения: `Brand.key("Folder")` → `NektoFolder`,
    /// в командной строке `-NektoFolder`. Так ключи не спутать с системными (`-AppleLanguages`).
    static func key(_ suffix: String) -> String { name + suffix }
}

/// Следы приложения на Mac: что и где оставляет приложение с таким именем и идентификатором.
///
/// `Footprint.current`: по нему строятся пути (`AppPaths`) и стирание данных в настройках.
struct Footprint: Sendable {
    let name: String
    let bundleID: String
    let historyFolder: String
    /// `~/Library` и `~/Documents`.
    let library: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    static let current = Footprint(name: Brand.name, bundleID: Brand.bundleID, historyFolder: Brand.historyFolder)

    /// Среда Python, модель и отметка об установке.
    var support: URL { library.appendingPathComponent("Application Support/\(name)", isDirectory: true) }
    /// Кеш загрузок и uv: можно удалить в любой момент.
    var caches: URL { library.appendingPathComponent("Caches/\(name)", isDirectory: true) }
    var logs: URL { library.appendingPathComponent("Logs/\(name)", isDirectory: true) }
    /// TipKit помнит здесь, какие подсказки человек уже видел.
    var tips: URL { library.appendingPathComponent("Application Support/\(bundleID)", isDirectory: true) }
    /// То, что система заводит сама по идентификатору бандла. Ничего невосполнимого.
    var systemTails: [URL] {
        ["Caches/\(bundleID)", "HTTPStorages/\(bundleID)", "Saved Application State/\(bundleID).savedState"]
            .map { library.appendingPathComponent($0) }
    }
    /// Файл настроек. Читать и писать настройки нужно через `UserDefaults`; путь нужен, только чтобы убрать файл,
    /// который система оставляет пустым после удаления домена.
    var preferencesFile: URL { library.appendingPathComponent("Preferences/\(bundleID).plist") }
    /// Рабочая папка, которую приложение предлагает создать: «Документы › Nekto».
    var suggestedFolder: URL { documents.appendingPathComponent(name, isDirectory: true).standardizedFileURL }

    /// Всё в «Библиотеке», что стирает «Стереть все данные».
    var everythingInLibrary: [URL] { [support, caches, logs, tips, preferencesFile] + systemTails }

    func key(_ suffix: String) -> String { name + suffix }
}
