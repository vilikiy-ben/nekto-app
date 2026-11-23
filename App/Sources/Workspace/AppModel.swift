import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Корневое состояние приложения: установка, рабочая папка, история обработок, навигация.
/// Обработка документов (очередь, движок, правки) — в `AppModel+Pipeline.swift`.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case launching, welcome, setup, ready }
    enum EngineState: Equatable { case idle, warming, ready, failed(String) }

    /// Куда смотрит окно. Стрелки ‹ › в верхней полосе ходят по этим точкам.
    enum Place: Equatable {
        case home
        case settings
        case processing(UUID)
        case reader(processing: UUID, job: UUID)
    }

    init() {
        composer.modes = reviewPrefs.defaultModes
    }

    var phase: Phase = .launching
    /// Шаг онбординга до установки (фаза `.welcome`): знакомство, как это работает, что скачается.
    /// Дальше шаг следует за фазой: `.setup` — ход установки, `.ready` без папок — выбор папки (`OnboardingStep`).
    var welcomePage: OnboardingStep = .intro
    let installer = Installer()
    let folders = WorkFolders()
    let composer = Composer()
    /// Свёрнутые группы «Скрыто» и режимы для новых обработок — между запусками.
    let reviewPrefs = ReviewPreferences()

    /// История каждой папки из боковой панели, новые обработки сверху.
    private(set) var histories: [URL: [Processing]] = [:]
    private(set) var place: Place = .home
    private var backStack: [Place] = []
    private var forwardStack: [Place] = []

    var showSidebar = true
    var showInspector = false
    /// Ширина окна и боковой панели — чтобы три колонки не налезали друг на друга.
    var layoutWidth: CGFloat = 0
    /// Заголовок в панели инструментов создаётся заново, когда ширина окна устоялась. Окно сузилось — система могла
    /// убрать заголовок в «»» панели, а оттуда он сам не возвращается: его место больше не меряется (`Breadcrumbs`).
    var titleEpoch = 0
    var sidebarWidth: CGFloat = Metrics.sidebarDefault
    /// Где в панели инструментов кончаются кнопки слева и начинается значок «Скрыто» справа (координаты окна).
    /// По ним заголовку задаётся ширина, при которой он помещается между кнопками и ничего не вытесняет.
    var toolbarLeading: CGFloat?
    var toolbarTrailing: CGFloat?
    var confirmDelete: Processing?
    /// Где стояла лента каждой обработки, когда из неё ушли (`FeedPlace`). Вернулись — она там же, а не у конца.
    /// Только на время работы: после перезапуска лента открывается с конца, как чат.
    @ObservationIgnored var feedPlaces: [UUID: FeedPlace] = [:]
    /// Что показать в тексте редактора системным индикатором поиска: метку или значение. `tick` — сигнал повтора.
    private(set) var spotlightRequest: (target: String, tick: Int) = ("", 0)
    var renaming: UUID?
    /// Метка под курсором в тексте редактора: её строка в «Скрыто» подсвечена. Вместо подсказки над меткой.
    var hoveredTag: String?
    /// Файлы из Finder, пришедшие до того, как приложение готово (установка, выбор папки).
    private var pendingExternal: [URL] = []

    // Конвейер (см. AppModel+Pipeline)
    var engine: EngineState = .idle
    var engineExtensions: Set<String> = []
    var loadedSessions: Set<UUID> = []
    var queue: [Job] = []
    var pumping = false
    /// Обработки, у которых идут задания: при возврате в папку история подхватывает живые объекты.
    var live: [UUID: Processing] = [:]

    // MARK: Производные

    var current: Processing? {
        switch place {
        case .home, .settings: nil
        case .processing(let id), .reader(let id, _): processing(id)
        }
    }

    var readerJob: Job? {
        guard case .reader(_, let jobID) = place else { return nil }
        return current?.items.first { $0.id == jobID }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    /// Папка, куда попадёт новая обработка.
    var workFolder: URL? { folders.current }
    var needsFolder: Bool { phase == .ready && folders.isEmpty }

    func history(_ root: URL) -> [Processing] { histories[root.standardizedFileURL] ?? [] }

    /// Панель «Скрыто» живёт только в редакторе: там видно текст целиком, и правки сразу заметны.
    var inspectorAvailable: Bool { readerJob.map { !$0.isReply } ?? false }

    func processing(_ id: UUID) -> Processing? {
        for list in histories.values { if let p = list.first(where: { $0.id == id }) { return p } }
        return live[id]
    }

    // MARK: Запуск

    func bootstrap() {
        guard phase == .launching else { return }
        folders.validate()
        reloadAll()
        if Installer.isInstalled() {
            phase = .ready
            warmEngine()
            flushExternal()
        } else {
            phase = Installer.hasEverStarted ? .setup : .welcome
            if phase == .setup { startSetup() }
        }
        DebugScenario.apply(to: self)
    }

    func startSetup() {
        phase = .setup
        Task {
            if let rehearsal = DebugScenario.setupRehearsal { await installer.rehearse(rehearsal) } else { await installer.run() }
            if installer.isDone {
                try? await Task.sleep(for: .milliseconds(900))  // дать отметке «Готово» отыграть
                phase = .ready
                warmEngine()
                flushExternal()
            }
        }
    }

    // MARK: Рабочие папки

    func useSuggestedFolder() { addFolder(WorkFolders.suggested) }

    /// «+» у списка папок: выбрать папку в Finder и добавить её в боковую панель.
    func chooseFolder() {
        guard let url = folders.pick() else { return }
        addFolder(url)
    }

    func addFolder(_ url: URL) {
        let root = folders.add(url)
        reloadHistory(root)
        flushExternal()
    }

    /// Убрать папку из боковой панели. Файлы и история на диске остаются: папку можно добавить снова.
    func removeFolder(_ url: URL) {
        folders.remove(url)
        histories[url] = nil
        backStack.removeAll { $0.processingID.flatMap(processing)?.root == url }
        forwardStack.removeAll { $0.processingID.flatMap(processing)?.root == url }
        if current?.root == url { place = .home }
    }

    /// Новая обработка именно в этой папке.
    func newProcessing(in url: URL) {
        folders.setCurrent(url)
        newProcessing()
    }

    func reloadAll() {
        histories = [:]
        for root in folders.list { reloadHistory(root) }
    }

    func reloadHistory(_ root: URL) {
        let list = Store.loadAll(root: root).map { live[$0.id] ?? $0 }
        histories[root] = list
        for p in list { resumeStale(p) }
    }

    func revealFolder(_ url: URL? = nil) {
        guard let root = url ?? folders.current else { return }
        NSWorkspace.shared.open(root)
    }

    // MARK: Панели

    /// Хватает ли окна на историю, ленту и «Скрыто» одновременно.
    private var fitsBothPanels: Bool { layoutWidth == 0 || layoutWidth >= sidebarWidth + Metrics.inspectorDefault + 440 }

    /// Последнее действие побеждает: если места на три колонки нет, вторая панель уступает.
    func toggleSidebar() {
        showSidebar.toggle()
        if showSidebar, showInspector, !fitsBothPanels { showInspector = false }
    }

    func toggleInspector() {
        showInspector.toggle()
        if showInspector, showSidebar, !fitsBothPanels { showSidebar = false }
    }

    /// Окно сузили — сначала прячем историю, лента важнее.
    func fitPanels() {
        if showSidebar, showInspector, inspectorAvailable, !fitsBothPanels { showSidebar = false }
    }

    // MARK: Навигация

    func go(_ target: Place) {
        guard target != place else { return }
        backStack.append(place)
        forwardStack.removeAll()
        place = target
        prepare(target)
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(place)
        place = validated(target)
        prepare(place)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(place)
        place = validated(target)
        prepare(place)
    }

    func newProcessing() {
        composer.reset(modes: reviewPrefs.defaultModes)
        go(.home)
        composer.focusRequest += 1
    }

    func openSettings() { go(.settings) }

    func open(_ p: Processing) {
        folders.setCurrent(p.root)
        go(.processing(p.id))
    }

    func openReader(_ job: Job) {
        guard let p = job.processing else { return }
        go(.reader(processing: p.id, job: job.id))
    }

    /// «Открыть в редакторе»: документ целиком и панель «Скрыто» рядом — сразу, без поиска переключателя.
    func openInEditor(_ job: Job) {
        openReader(job)
        guard inspectorAvailable, !showInspector else { return }
        showInspector = true
        if showSidebar, !fitsBothPanels { showSidebar = false }
    }

    func spotlight(_ target: String) {
        spotlightRequest = (target, spotlightRequest.tick + 1)
    }

    func closeReader() {
        if case .reader(let pid, _) = place { go(.processing(pid)) }
    }

    private func validated(_ target: Place) -> Place {
        switch target {
        case .home: return .home
        case .settings: return .settings
        case .processing(let id): return processing(id) == nil ? .home : target
        case .reader(let pid, let jid):
            guard let p = processing(pid) else { return .home }
            return p.items.contains { $0.id == jid } ? target : .processing(pid)
        }
    }

    private func prepare(_ target: Place) {
        if let p = current { Store.hydrate(p) }
        if case .home = target { composer.focusRequest += 1 }
        if !inspectorAvailable { showInspector = false }
    }

    // MARK: История

    func rename(_ p: Processing, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !clean.isEmpty, clean != p.title else { return }
        p.title = clean
        p.customTitle = true
        Store.renameOutputFolder(of: p)
        Store.save(p)
    }

    func delete(_ p: Processing, includingFiles: Bool) {
        p.isDeleted = true
        for job in p.items { job.task?.cancel() }
        queue.removeAll { $0.processing === p }
        Store.trash(p, includingResults: includingFiles)
        histories[p.root]?.removeAll { $0.id == p.id }
        live[p.id] = nil
        feedPlaces[p.id] = nil
        loadedSessions.remove(p.id)
        Task { _ = try? await EngineClient.shared.call("drop", ["session": .string(p.id.uuidString)]) }
        backStack.removeAll { $0.processingID == p.id }
        forwardStack.removeAll { $0.processingID == p.id }
        if place.processingID == p.id { place = .home; composer.focusRequest += 1 }
    }

    func revealOutput(of p: Processing) {
        if let folder = p.outputFolder, FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            revealFolder(p.root)
        }
    }

    /// Свежая обработка поднимается наверх списка, как чат с новым сообщением.
    func touch(_ p: Processing) {
        p.updatedAt = Date()
        guard var list = histories[p.root], let i = list.firstIndex(where: { $0.id == p.id }), i != 0 else { return }
        list.remove(at: i)
        list.insert(p, at: 0)
        histories[p.root] = list
    }

    func insertIntoHistory(_ p: Processing) {
        var list = histories[p.root] ?? []
        list.removeAll { $0.id == p.id }
        list.insert(p, at: 0)
        histories[p.root] = list
    }

    // MARK: Результат

    func copy(_ output: JobOutput) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(output.text, forType: .string)
    }

    func reveal(_ output: JobOutput) {
        guard let file = output.fileURL, FileManager.default.fileExists(atPath: file.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    // MARK: Ввод

    func openFiles(directories: Bool = false, types: [UTType] = []) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = !directories
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.prompt = directories ? "Выбрать папку" : "Добавить"
        if panel.runModal() == .OK { composer.attach(panel.urls) }
        composer.focusRequest += 1
    }

    func pasteFromClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            composer.attach(urls)
        } else if let text = pb.string(forType: .string) {
            composer.insert(text)
        }
        composer.focusRequest += 1
    }

    /// Файлы, открытые через Finder («Открыть в программе») или брошенные на иконку в Dock: сразу новая обработка.
    func openExternally(_ urls: [URL]) {
        guard phase == .ready, folders.current != nil else { pendingExternal.append(contentsOf: urls); return }
        place = .home
        composer.reset(modes: reviewPrefs.defaultModes)
        composer.attach(urls)
        send()
    }
}

extension AppModel {
    fileprivate func flushExternal() {
        guard !pendingExternal.isEmpty, phase == .ready, folders.current != nil else { return }
        let urls = pendingExternal
        pendingExternal.removeAll()
        openExternally(urls)
    }
}

extension AppModel.Place {
    var processingID: UUID? {
        switch self {
        case .home, .settings: nil
        case .processing(let id), .reader(let id, _): id
        }
    }
}
