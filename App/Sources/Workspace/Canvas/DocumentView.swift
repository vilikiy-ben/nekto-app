import AppKit
import SwiftUI

/// Документ в редакторе и в ленте: форма документа (таблицы, слайды, поля письма, код) с метками.
///
/// - Метки `[ФИО_1]` — моноширинные «пилюли» акцентного цвета; серые — значение решили не скрывать.
/// - Подсмотреть исходные данные — пока зажата ⌥, на местах меток видны значения. Отпустил — снова метки.
/// - В редакторе метка под курсором подсвечивает свою строку в «Скрыто» (`onHoverTag`).
/// - В ответе нейросети вернувшиеся данные подсвечены зелёным.
/// - Контекстное меню: «Скрыть» выделенное, если модель пропустила; «Не скрывать» на метке, если ошиблась.
///
/// Документ раскладывается в фоне (`SceneBuilder`, `SceneWorker`) и рисуется своим холстом (`DocumentCanvasView`):
/// прежний вид на NSTextView/NSTextTable терял строки при рисовании больших таблиц и раскладывал всё на главном
/// потоке (`docs/ARCHITECTURE.md` → «Интерфейс»). Правка в «Скрыто» перекрашивает метки сразу, а новый текст после
/// пересчёта встаёт на место без прыжка прокрутки: раскладываются заново только изменившиеся ячейки.
struct DocumentView: NSViewRepresentable {
    /// `placeholders` — обезличенный документ, метки «пилюлями»; `restored` — ответ нейросети, вернувшиеся данные зелёным.
    enum Highlight: Equatable { case placeholders, restored }

    var document: DocumentLayout
    var highlight: Highlight = .placeholders
    var originals: [String: String] = [:]
    /// Решения пользователя: какие метки серые (значение больше не скрывается) и какие значения стоят в тексте открытыми.
    var decisions = TextDecisions()
    /// Встроенный вариант для ленты: без прокрутки, высота по содержимому.
    var inline = false
    var onHide: ((String, String) -> Void)? = nil
    var onUnhide: ((String) -> Void)? = nil
    var onRehide: ((String) -> Void)? = nil
    /// Показать метку или значение жёлтым индикатором поиска, как ⌘F в любом тексте macOS.
    var spotlight: (target: String, tick: Int) = ("", 0)
    /// Метка под курсором (или `nil`). Задан — текст следит за мышью.
    var onHoverTag: ((String?) -> Void)? = nil

    /// Подсмотреть можно только обезличенный текст, где есть что показывать.
    var canPeek: Bool { highlight == .placeholders && !originals.isEmpty }

    func makeNSView(context: Context) -> NSView {
        let c = context.coordinator
        let canvas = DocumentCanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        c.canvas = canvas
        canvas.menuProvider = { [weak c] index, mark in c?.menu(index: index, mark: mark) }
        if onHoverTag != nil {
            canvas.onHoverMark = { [weak c] mark in c?.parent.onHoverTag?(mark?.key) }
        }
        c.watchModifiers()
        if inline {
            canvas.inset = SceneStyle.inlineInset
            c.refresh()
            return canvas
        }
        canvas.inset = SceneStyle.readerInset
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = canvas
        canvas.enableFind(in: scroll)
        c.watchScroll(scroll)
        c.refresh()
        #if DEBUG
        ScrollBench.startIfRequested(on: scroll)
        #endif
        return scroll
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh()
        if spotlight.tick != context.coordinator.spotlightTick {
            context.coordinator.spotlightTick = spotlight.tick
            context.coordinator.spotlight(spotlight.target)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        // Редактор занимает ровно предложенное место: широкая таблица прокручивается внутри, а не раздвигает окно.
        guard inline else { return CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400) }
        let width = max(proposal.width ?? 600, 100)
        context.coordinator.inlineWidth = width - SceneStyle.inlineInset.width * 2
        context.coordinator.refresh()
        let scene = context.coordinator.canvas?.scene ?? .empty
        return CGSize(width: width, height: ceil(scene.size.height + SceneStyle.inlineInset.height * 2))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopWatching()
    }

    // MARK: -

    @MainActor
    final class Coordinator: NSObject {
        var parent: DocumentView
        weak var canvas: DocumentCanvasView?
        var spotlightTick = 0
        /// Ширина карточки в ленте (из `sizeThatFits`).
        var inlineWidth: CGFloat = 0

        private let worker = SceneWorker()
        /// Что заказано последним: тот же документ с теми же настройками заново не раскладывается.
        private var requested: (document: DocumentLayout, options: SceneBuilder.Options)?
        private var pendingSpotlight: String?
        private var fade: EdgeFade?
        private var observers: [NSObjectProtocol] = []
        /// Зажата ⌥: вместо меток видны исходные значения.
        private(set) var peeking = false
        private var flagsMonitor: Any?
        private var pendingPeek: DispatchWorkItem?
        private var selectionBeforePeek: NSRange?
        /// Отладочный сценарий (`DocumentView+Debug`) уже отработал.
        var debugScenarioDone = false

        init(parent: DocumentView) { self.parent = parent }

        // MARK: Сборка

        private var layoutWidth: CGFloat {
            if parent.inline { return inlineWidth > 0 ? inlineWidth : 600 }
            guard let clip = canvas?.enclosingScrollView?.contentView, clip.bounds.width > 100 else { return 780 }
            return clip.bounds.width - SceneStyle.readerInset.width * 2
        }

        private var options: SceneBuilder.Options {
            let peek = peeking && parent.canPeek
            return SceneBuilder.Options(
                width: floor(layoutWidth), inline: parent.inline,
                text: SceneTextOptions(replies: parent.highlight == .restored, peek: peek, originals: peek ? parent.originals : [:],
                                       shown: parent.highlight == .placeholders ? parent.decisions.shown : [:]))
        }

        /// Свести экран к текущему состоянию: решения — сразу (только цвет), форма — по готовности сцены.
        func refresh() {
            guard let canvas else { return }
            canvas.decisions = parent.highlight == .placeholders ? parent.decisions : TextDecisions()
            let options = self.options
            let document = parent.document
            if let requested, requested.options == options, requested.document == document { return }
            requested = (document, options)
            let builder = SceneBuilder(options: options, cache: worker.cache)
            // Маленький документ (и карточка в ленте) — сразу, без кадра пустоты; большой — в фоне, на экране пока прежний вид.
            if parent.inline || document.weight < 30_000 {
                worker.cancel()
                show(builder.build(document))
            } else {
                worker.submit(build: { builder.build(document) }) { [weak self] scene in self?.show(scene) }
            }
        }

        private func show(_ scene: DocumentScene) {
            guard let canvas else { return }
            canvas.setScene(scene)
            if parent.inline { showFade(scene.size.width > layoutWidth + 1) }
            if !peeking, let saved = selectionBeforePeek {
                selectionBeforePeek = nil
                if NSMaxRange(saved) <= scene.textLength { canvas.selection = saved }
            }
            if let target = pendingSpotlight {
                pendingSpotlight = nil
                spotlight(target)
            }
            #if DEBUG
            runDebugScenario()
            #endif
        }

        private func showFade(_ on: Bool) {
            guard let canvas else { return }
            if on, fade == nil {
                let f = EdgeFade(color: Ink.nsRaised)
                f.frame = NSRect(x: canvas.bounds.maxX - EdgeFade.width, y: 0, width: EdgeFade.width, height: canvas.bounds.height)
                f.autoresizingMask = [.minXMargin, .height]
                canvas.addSubview(f)
                fade = f
            }
            fade?.isHidden = !on
        }

        // MARK: Прокрутка и ширина

        func watchScroll(_ scroll: NSScrollView) {
            let clip = scroll.contentView
            clip.postsFrameChangedNotifications = true
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.canvas?.updateSize()
                    self?.refresh()
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.canvas?.updateSticky() }
            })
        }

        func stopWatching() {
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
            pendingPeek?.cancel()
            worker.cancel()
            // Редактор закрывается — подсветка в «Скрыто» гаснет. Не посреди обновления представлений.
            if let report = parent.onHoverTag { DispatchQueue.main.async { report(nil) } }
        }

        // MARK: Поиск из «Скрыто»

        /// Следующее вхождение после выделения (повторный щелчок идёт дальше по тексту), с прокруткой и вспышкой.
        func spotlight(_ target: String) {
            guard !target.isEmpty, let canvas else { return }
            guard canvas.scene.textLength > 0 else { pendingSpotlight = target; return }
            let ns = canvas.scene.nsText
            let start = NSMaxRange(canvas.selection)
            var r = start < ns.length
                ? ns.range(of: target, options: .caseInsensitive, range: NSRange(location: start, length: ns.length - start))
                : NSRange(location: NSNotFound, length: 0)
            if r.location == NSNotFound { r = ns.range(of: target, options: .caseInsensitive) }
            guard r.location != NSNotFound else { NSSound.beep(); return }
            canvas.spotlight(r)
        }

        // MARK: Подсмотреть исходные данные (⌥)

        func watchModifiers() {
            guard flagsMonitor == nil else { return }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated { self?.modifiersChanged(event.modifierFlags) }
                return event
            }
            // Окно ушло на второй план с зажатой ⌥ — отпускания мы не увидим.
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPeek(false) }
            })
        }

        /// Только ⌥, без других клавиш: ⌥⌘ и ⇧⌥ — это сочетания, а не «подсмотреть».
        /// Короткая пауза — чтобы ⌥, нажатая по пути к ⌥⌘…, не мигала значениями.
        private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
            pendingPeek?.cancel()
            let optionOnly = flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .option
            guard optionOnly, parent.canPeek, let canvas, let window = canvas.window, window.isKeyWindow, !canvas.isHiddenOrHasHiddenAncestor else {
                setPeek(false)
                return
            }
            let work = DispatchWorkItem { [weak self] in self?.setPeek(true) }
            pendingPeek = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        func setPeek(_ on: Bool) {
            guard on != peeking, let canvas else { return }
            if on {
                selectionBeforePeek = canvas.selection.length > 0 ? canvas.selection : nil
                Teaching.learned(PeekTip())
            }
            peeking = on
            canvas.isTextSelectable = !on
            refresh()
        }

        // MARK: Контекстное меню: исправление ошибок модели

        func menu(index: Int?, mark: SceneMark?) -> NSMenu? {
            guard let canvas else { return nil }
            // Текст только для чтения: шрифты, правописание и замены здесь не нужны.
            let menu = NSMenu()
            let copy = menu.addItem(withTitle: "Скопировать", action: #selector(DocumentCanvasView.copy(_:)), keyEquivalent: "")
            copy.target = canvas
            let all = menu.addItem(withTitle: "Выбрать всё", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "")
            all.target = canvas
            guard parent.onHide != nil, !peeking else { return menu }
            var items: [NSMenuItem] = []
            let selected = canvas.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty, !selected.contains("\t"),
               DocumentText.tagRegex.firstMatch(in: selected, range: NSRange(location: 0, length: (selected as NSString).length)) == nil {
                let short = selected.count > 30 ? String(selected.prefix(28)) + "…" : selected
                items.append(action("Скрыть «\(short)»", #selector(hideAsOther(_:)), selected))
                items.append(action("Скрыть как ФИО", #selector(hideAsPerson(_:)), selected))
            }
            if let mark = mark ?? index.flatMap({ canvas.scene.mark(atText: $0) }), mark.kind != .restored {
                // Серая метка — значение уже решили не скрывать, текст ещё не обновился.
                let value = mark.kind == .tag ? (parent.originals[mark.key].map { "«\($0)»" } ?? mark.key) : "«\(parent.originals[mark.key] ?? mark.key)»"
                if parent.decisions.isHidden(mark.key) {
                    items.append(action("Не скрывать \(value)", #selector(unhide(_:)), mark.key))
                } else {
                    items.append(action("Снова скрывать \(value)", #selector(rehide(_:)), mark.key))
                }
            }
            guard !items.isEmpty else { return menu }
            for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
            menu.insertItem(.separator(), at: items.count)
            return menu
        }

        private func action(_ title: String, _ selector: Selector, _ payload: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = payload
            return item
        }

        @objc private func hideAsOther(_ sender: NSMenuItem) { (sender.representedObject as? String).map { parent.onHide?($0, "ПДН") } }
        @objc private func hideAsPerson(_ sender: NSMenuItem) { (sender.representedObject as? String).map { parent.onHide?($0, "ФИО") } }
        @objc private func unhide(_ sender: NSMenuItem) { (sender.representedObject as? String).map { parent.onUnhide?($0) } }
        @objc private func rehide(_ sender: NSMenuItem) { (sender.representedObject as? String).map { parent.onRehide?($0) } }
    }
}

/// Сборка сцен в фоне: одна очередь, считается только самая свежая просьба. Пока окно тянут за край,
/// просьбы идут каждый кадр — промежуточные пропускаются, а главный поток не ждёт ни одной.
final class SceneWorker: @unchecked Sendable {
    let cache = TextLayoutCache()
    private let queue = DispatchQueue(label: Brand.key("scene"), qos: .userInitiated)
    private let lock = NSLock()
    private var latest = 0

    private func isLatest(_ ticket: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ticket == latest
    }

    /// Отменить заказанное: старая сцена не придёт поверх новой.
    func cancel() {
        lock.lock(); latest += 1; lock.unlock()
    }

    func submit(build: @escaping @Sendable () -> DocumentScene, done: @escaping @MainActor (DocumentScene) -> Void) {
        lock.lock(); latest += 1; let ticket = latest; lock.unlock()
        queue.async { [self] in
            guard isLatest(ticket) else { return }
            let scene = build()
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    guard isLatest(ticket) else { return }
                    done(scene)
                }
            }
        }
    }
}

extension DocumentLayout {
    /// Примерный объём текста (UTF-8, без обхода символов): решает, раскладывать ли сразу или в фоне.
    var weight: Int {
        func w(_ blocks: [DocBlock]) -> Int {
            blocks.reduce(0) { sum, b in
                switch b {
                case .heading(let t, _), .paragraph(let t, _), .item(let t, _, _), .code(let t, _), .note(let t): sum + t.utf8.count
                case .table(let t): sum + t.rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.text.utf8.count + 4 } }
                case .fields(let rows): sum + rows.reduce(0) { $0 + $1.label.utf8.count + $1.value.utf8.count }
                case .section(let s): sum + w(s.blocks)
                }
            }
        }
        return w(blocks)
    }
}
