import AppKit

/// Аргументы запуска для проверки интерфейса и снимков экрана — без кликов по экрану:
///
///     open Nekto.app --args -NektoFolder ~/tmp/work -NektoOpen 0 -NektoInspector YES
///
/// - `NektoFolder` — рабочая папка (ничего не запоминается, см. `WorkFolders`);
/// - `NektoOpen` — открыть обработку по номеру в истории (0 — самая свежая);
/// - `NektoReader` — открыть документ целиком (номер в обработке);
/// - `NektoInspector`, `NektoHideSidebar` — показать/скрыть панели;
/// - `NektoDraft` — текст в строке ввода;
/// - `NektoAttach` — прикрепить файлы (через «|»); `NektoSend` — сразу отправить;
/// - `NektoSpotlight` — показать в редакторе метку или значение индикатором поиска;
/// - `NektoUnhide` — снять галочку «скрывать» у метки открытой обработки, как щелчок в «Скрыто» (метка — в кавычках
///   plist: `'"[ФИО_1]"'`); проверка точечного обновления документа с таблицами;
/// - `NektoToggleSidebar` — переключить боковую панель, затем открыть настройки;
/// - `NektoWindowWidth`, `NektoWindowHeight` — размер окна в точках (проверка узкого и низкого окна);
/// - `NektoReview` — открыть документ (номер в обработке) как по кнопке «Открыть в редакторе»;
/// - `NektoResetTips`, `NektoTipsImmediate` — обучающие подсказки заново и без паузы (`Teaching`);
/// - `NektoWelcome` — показать первый экран онбординга, ничего не удаляя (то же, что `NektoOnboarding intro`);
/// - `NektoOnboarding` — открыть шаг онбординга: `intro`, `how`, `install` (до установки), `setup` (ход установки
///   до конца и переход к папке), `progress` (ход установки стоит на 46 %, как в макете), `error` (установка
///   срывается с ошибкой сети), `folder` (выбор папки). Папок нет, выбранная не запоминается (`WorkFolders`);
///   установка — репетиция `Installer.rehearse`: ничего не скачивается, настоящая модель на Mac не трогается;
/// - `NektoSuggestedFolder` — куда «Начать работу» заведёт папку вместо «Документы › Nekto»;
/// - `NektoPickFolder` — что «выберет» панель выбора папки (без окна; только вместе с `NektoOnboarding` или `NektoFolder`);
/// - `NektoSceneLog` — раз в 2 с писать в журнал, сколько кадров нарисовала сцена онбординга (`SceneHost`);
/// - `NektoSceneFPS` — потолок частоты кадров сцены вместо `SceneHost.frameRate` (0 — как у экрана), для замеров;
/// - `NektoReduceMotion` — онбординг ведёт себя как при «Уменьшить движение», не трогая настройку системы;
/// - `NektoAbout` — открыть окно «О программе».
/// - `NektoDelete <n>` — через 1,5 с спросить об удалении обработки по номеру в истории, как «Удалить…» в меню строки
///   (так появление листа можно снять серией кадров; ничего не удаляется, пока не нажата «Удалить»).
/// - Панель «Скрыто» (`Workspace/Review`): `NektoCollapse "НОМЕР|ИНН"` — свернуть группы (запоминается в наборе
///   настроек сценариев, `ReviewPreferences`), `NektoExpandAll YES` — развернуть все; `NektoReviewFilter <текст>` —
///   текст в фильтре; `NektoToggleGroup "ДАТА|ОРГ"` — щелчки по флажкам групп открытого документа через 2 с, по одному
///   в секунду; `NektoUndo <n>` — затем n раз «Отменить»; `NektoResetReviewPrefs YES` — забыть свёрнутое и режимы.
///
/// Всё это — только в Debug-сборке: ключи читаются через `DebugDefaults`, а в выпуске он пуст.
@MainActor
enum DebugScenario {
    /// Шаг онбординга из `-NektoOnboarding`.
    static var onboarding: String? { DebugDefaults.string("Onboarding") }

    /// Онбординг открыт отладочным сценарием — установка идёт репетицией, а не по-настоящему.
    static var setupRehearsal: Installer.Rehearsal? {
        switch onboarding {
        case "progress": .hold
        case "error": .fail
        case .some: .complete
        case nil: DebugDefaults.flag("Welcome") ? .complete : nil
        }
    }

    /// `-NektoReviewFilter <текст>`: что стоит в фильтре «Скрыто» при открытии.
    static var reviewFilter: String? { DebugDefaults.string("ReviewFilter") }

    /// `-NektoReduceMotion YES`: как системное «Уменьшить движение», только для онбординга.
    static var reduceMotion: Bool { DebugDefaults.flag("ReduceMotion") }

    static func apply(to model: AppModel) {
        guard let d = DebugDefaults.store else { return }
        if let index = d.object(forKey: Brand.key("Open")) as? Int ?? Int(d.string(forKey: Brand.key("Open")) ?? ""),
           let root = model.workFolder, model.history(root).indices.contains(index) {
            let p = model.history(root)[index]
            model.open(p)
            if let j = Int(d.string(forKey: Brand.key("Reader")) ?? ""), p.items.indices.contains(j) { model.openReader(p.items[j]) }
            if let j = Int(d.string(forKey: Brand.key("Review")) ?? ""), p.items.indices.contains(j) { model.openInEditor(p.items[j]) }
        }
        if d.bool(forKey: Brand.key("Inspector")) { model.showInspector = true }
        if d.bool(forKey: Brand.key("HideSidebar")) { model.showSidebar = false }
        if let draft = d.string(forKey: Brand.key("Draft")) { model.composer.text = draft.replacingOccurrences(of: "\\n", with: "\n") }
        if let extra = d.string(forKey: Brand.key("ExtraFolder")) { model.addFolder(URL(fileURLWithPath: extra)); model.folders.setCurrent(model.folders.list[0]) }
        if let attach = d.string(forKey: Brand.key("Attach")) {
            model.composer.attach(attach.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
        }
        if let tag = d.string(forKey: Brand.key("Unhide")) {
            Task {
                try? await Task.sleep(for: .seconds(2))
                if let p = model.current { model.setHidden(tag, false, in: p) }
            }
        }
        if let target = d.string(forKey: Brand.key("Spotlight")) {
            Task { try? await Task.sleep(for: .seconds(1.5)); model.spotlight(target) }
        }
        let width = Double(d.string(forKey: Brand.key("WindowWidth")) ?? "")
        let height = Double(d.string(forKey: Brand.key("WindowHeight")) ?? "")
        if width != nil || height != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                for w in NSApp.windows where w.isVisible && w.frame.width > 400 {
                    let h = height ?? w.frame.height
                    w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - h, width: width ?? w.frame.width, height: h), display: true)
                }
            }
        }
        if d.bool(forKey: Brand.key("ToggleSidebar")) {
            // Переключить боковую панель, затем открыть настройки: проверка раскладки панели инструментов.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5)); model.toggleSidebar()
                try? await Task.sleep(for: .seconds(1)); model.openSettings()
            }
        }
        if d.bool(forKey: Brand.key("Settings")) {
            model.openSettings()
        }
        if d.bool(forKey: Brand.key("Welcome")) {
            model.phase = .welcome
        }
        switch onboarding {
        case "intro", "how", "install":
            model.phase = .welcome
            model.welcomePage = OnboardingStep(debugName: onboarding ?? "") ?? .intro
        case "setup", "progress", "error":
            if model.phase != .setup { model.startSetup() }
        case "folder":
            model.phase = .ready
        default: break
        }
        if let index = Int(d.string(forKey: Brand.key("Delete")) ?? ""), let root = model.workFolder,
           model.history(root).indices.contains(index) {
            // Как «Удалить…» в меню строки истории: появление диалога снимается без кликов.
            Task { @MainActor in try? await Task.sleep(for: .seconds(1.5)); model.confirmDelete = model.history(root)[index] }
        }
        if d.bool(forKey: Brand.key("About")) {
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(500)); AboutPanel.show() }
        }
        applyReview(to: model, d)
        if d.bool(forKey: Brand.key("Send")) {
            Task {
                // Ждём модель, чтобы снимок показал результат, а не очередь.
                for _ in 0..<600 where model.engine != .ready { try? await Task.sleep(for: .milliseconds(100)) }
                model.send()
            }
        }
    }

    private static func applyReview(to model: AppModel, _ d: UserDefaults) {
        if d.bool(forKey: Brand.key("ExpandAll")) { model.reviewPrefs.setCollapsed(model.reviewPrefs.collapsedKinds, false) }
        if let kinds = d.string(forKey: Brand.key("Collapse")) {
            model.reviewPrefs.setCollapsed(kinds.split(separator: "|").map(String.init), true)
        }
        let toggles = d.string(forKey: Brand.key("ToggleGroup"))?.split(separator: "|").map(String.init) ?? []
        let undos = d.integer(forKey: Brand.key("Undo"))
        guard !toggles.isEmpty || undos > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for kind in toggles {
                if let p = model.current, let job = model.readerJob,
                   let group = DocumentReview(processing: p, job: job).groups.first(where: { $0.kind == kind }) {
                    model.toggleGroup(group, in: p)
                }
                try? await Task.sleep(for: .seconds(1))
            }
            for _ in 0..<undos {
                AppModel.undoManager?.undo()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Откуда читаются отладочные ключи `-Nekto…`. В Debug-сборке это `UserDefaults.standard`, где лежат и аргументы
/// запуска. В выпуске хранилища нет: ни аргументы запуска, ни `defaults write` не откроют экран, не подменят папку,
/// не прикрепят и не отправят файлы.
enum DebugDefaults {
    static var store: UserDefaults? {
        #if DEBUG
        .standard
        #else
        nil
        #endif
    }

    static func string(_ name: String) -> String? { store?.string(forKey: Brand.key(name)) }
    static func flag(_ name: String) -> Bool { store?.bool(forKey: Brand.key(name)) ?? false }
    /// Число, если ключ задан: `-NektoSceneFPS 0` отличается от отсутствия ключа.
    static func integer(_ name: String) -> Int? {
        guard let store, store.object(forKey: Brand.key(name)) != nil else { return nil }
        return store.integer(forKey: Brand.key(name))
    }
}
