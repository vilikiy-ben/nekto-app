import AppKit
import SwiftUI

@main
struct NektoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel())
        Teaching.configure()
    }

    var body: some Scene {
        Window(Brand.name, id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 540)
                .onAppear {
                    delegate.model = model
                    model.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            NektoCommands(model: model)
            TextEditingCommands()   // «Правка → Найти» (⌘F, ⌘G) для редактора
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel? {
        didSet { if let model, !pending.isEmpty { model.openExternally(pending); pending.removeAll() } }
    }
    @MainActor private var pending: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Тема выбирается в настройках; по умолчанию как в системе.
        Appearance.saved.apply()
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.openExternally(urls) } else { pending.append(contentsOf: urls) }
    }
}

struct NektoCommands: Commands {
    let model: AppModel

    private var ready: Bool { model.phase == .ready && model.workFolder != nil }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("О программе \(Brand.name)") { AboutPanel.show() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Новая обработка") { model.newProcessing() }
                .keyboardShortcut("n")
                .disabled(!ready)
            Button("Добавить файлы…") { model.openFiles() }
                .keyboardShortcut("o")
                .disabled(!ready)
            Button("Вставить из буфера") { model.pasteFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!ready)
            Divider()
            Button("Добавить папку…") { model.chooseFolder() }
                .disabled(model.phase != .ready)
            Divider()
            Button("Удалить обработку…") { model.confirmDelete = model.current }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.current == nil)
        }
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .appSettings) {
            Button("Настройки…") { model.openSettings() }
                .keyboardShortcut(",")
                .disabled(model.phase != .ready || model.workFolder == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Скопировать результат") { if let o = lastOutput { model.copy(o) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(lastOutput == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(model.showSidebar ? "Скрыть боковую панель" : "Показать боковую панель") { model.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button(model.showInspector ? "Скрыть панель «Скрыто»" : "Показать панель «Скрыто»") { model.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!model.inspectorAvailable)
            Divider()
            // В онбординге ⌘[ — шаг назад, как кнопка «Назад» и Esc.
            Button("Назад") { if model.inOnboarding { model.stepBack() } else { model.goBack() } }
                .keyboardShortcut("[")
                .disabled(model.inOnboarding ? !model.canStepBack : !model.canGoBack)
            Button("Вперёд") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
        }
    }

    /// Результат, который нужен прямо сейчас: открытый документ или последний готовый в обработке.
    private var lastOutput: JobOutput? {
        if let job = model.readerJob { return job.output }
        return model.current?.items.last { $0.output != nil }?.output
    }
}
