import AppKit
import Foundation
import Observation

/// Рабочие папки. В каждой лежат обработки: обезличенные документы, ответы нейросети
/// и служебная `.nekto/` с историей. Боковая панель показывает все добавленные папки,
/// каждую можно свернуть. Новая обработка попадает в «текущую» папку: ту, где пользователь
/// работал последним, или ту, что он выбрал под строкой ввода.
///
/// Папки запоминаются закладками (bookmark), поэтому переименование или перенос в Finder
/// историю не теряет.
@MainActor
@Observable
final class WorkFolders {
    private(set) var list: [URL] = []
    private(set) var current: URL?
    private(set) var collapsed: Set<String> = []

    private static let listKey = "WorkFolderBookmarks"
    private static let currentKey = "WorkFolderBookmark"
    private static let collapsedKey = "CollapsedWorkFolders"
    private static let legacyRecentsKey = "RecentWorkFolderBookmarks"

    /// Предложение по умолчанию: ~/Documents/Nekto. Отладочный сценарий онбординга может подменить его
    /// (`-NektoSuggestedFolder /tmp/…`), чтобы «Начать работу» не заводило папку в настоящих «Документах».
    static var suggested: URL {
        if let forced = DebugDefaults.string("SuggestedFolder") {
            return URL(fileURLWithPath: (forced as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return Footprint.current.suggestedFolder
    }

    /// Режим проверки (`-NektoFolder /path`): одна папка, ничего не запоминается.
    private let isScenario: Bool

    init() {
        let defaults = UserDefaults.standard
        if DebugDefaults.string("Onboarding") != nil {
            // Отладочный сценарий онбординга (`-NektoOnboarding <шаг>`): папок нет, и выбранная не запоминается.
            isScenario = true
            return
        }
        if let forced = DebugDefaults.string("Folder") {
            isScenario = true
            let url = URL(fileURLWithPath: (forced as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            list = [url]
            current = url
            return
        }
        isScenario = false
        var urls = (defaults.array(forKey: Self.listKey) as? [Data] ?? []).compactMap(Self.resolve)
        let saved = defaults.data(forKey: Self.currentKey).flatMap(Self.resolve)
        if urls.isEmpty {
            // Раньше приложение помнило одну папку и список «недавних» — переносим их в общий список.
            urls = [saved].compactMap { $0 } + (defaults.array(forKey: Self.legacyRecentsKey) as? [Data] ?? []).compactMap(Self.resolve)
        }
        list = Self.unique(urls.filter(Self.exists))
        current = saved.flatMap { s in list.first { $0 == s.standardizedFileURL } } ?? list.first
        collapsed = Set(defaults.stringArray(forKey: Self.collapsedKey) ?? [])
    }

    var isEmpty: Bool { list.isEmpty }

    /// Чем отличить папку от другой с тем же именем: имя папки уровнем выше. `nil`, если имя единственное —
    /// тогда путь никому не нужен, и его не показываем (раньше он всплывал подсказкой у каждой папки).
    func distinction(_ url: URL) -> String? {
        let name = url.lastPathComponent
        guard list.contains(where: { $0 != url && $0.lastPathComponent == name }) else { return nil }
        return url.deletingLastPathComponent().lastPathComponent
    }

    /// Имя для меню и подписей: «Nekto», а при совпадении имён — «Nekto — Documents».
    func displayName(_ url: URL) -> String {
        distinction(url).map { "\(url.lastPathComponent) — \($0)" } ?? url.lastPathComponent
    }

    func isCollapsed(_ url: URL) -> Bool { collapsed.contains(url.path) }

    func toggleCollapsed(_ url: URL) {
        if collapsed.contains(url.path) { collapsed.remove(url.path) } else { collapsed.insert(url.path) }
        persist()
    }

    /// Добавить папку в боковую панель (или найти уже добавленную) и сделать её текущей.
    @discardableResult
    func add(_ url: URL) -> URL {
        let url = url.standardizedFileURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if !list.contains(url) { list.append(url) }
        collapsed.remove(url.path)
        current = url
        persist()
        return url
    }

    func setCurrent(_ url: URL) {
        let url = url.standardizedFileURL
        guard list.contains(url), current != url else { return }
        current = url
        persist()
    }

    /// Убрать папку из боковой панели. Файлы на диске остаются.
    func remove(_ url: URL) {
        list.removeAll { $0 == url }
        collapsed.remove(url.path)
        if current == url { current = list.first }
        persist()
    }

    /// Окно выбора папки: выбрать и сразу добавить. Возвращает добавленную папку или nil.
    func pick(prompt: String = "Добавить") -> URL? {
        choose(prompt: prompt).map { add($0) }
    }

    /// Окно выбора папки без добавления: онбординг сначала показывает выбор, а добавляет по «Начать работу».
    func choose(prompt: String = "Добавить", near start: URL? = nil) -> URL? {
        // Отладочный сценарий: панель «выбирает» заданную папку, без окна (`-NektoPickFolder /tmp/…`).
        if isScenario, let forced = DebugDefaults.string("PickFolder") {
            return URL(fileURLWithPath: (forced as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = "Сюда \(Brand.name) будет складывать обезличенные документы и историю обработок."
        panel.directoryURL = (start ?? current)?.deletingLastPathComponent() ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL
    }

    /// Папку удалили или отключили диск: убираем её из списка.
    func validate() {
        let alive = list.filter(Self.exists)
        guard alive.count != list.count else { return }
        list = alive
        if let c = current, !alive.contains(c) { current = alive.first }
        persist()
    }

    /// Всё забыть (стирание данных в настройках).
    func forgetAll() {
        list = []
        current = nil
        collapsed = []
        let defaults = UserDefaults.standard
        for key in [Self.listKey, Self.currentKey, Self.collapsedKey, Self.legacyRecentsKey] { defaults.removeObject(forKey: key) }
    }

    // MARK: Хранение

    private func persist() {
        guard !isScenario else { return }
        let defaults = UserDefaults.standard
        defaults.set(list.compactMap(Self.bookmark), forKey: Self.listKey)
        if let current, let data = Self.bookmark(current) { defaults.set(data, forKey: Self.currentKey) }
        else { defaults.removeObject(forKey: Self.currentKey) }
        defaults.set(Array(collapsed), forKey: Self.collapsedKey)
        defaults.removeObject(forKey: Self.legacyRecentsKey)
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }

    private static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale))?.standardizedFileURL
    }

    private static func exists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
