import AppKit

/// Холст документа: рисует разложенную сцену (`DocumentScene`) и даёт с ней работать — выделять, копировать,
/// искать (⌘F), исправлять ошибки модели из контекстного меню, следить за меткой под курсором.
///
/// Только для чтения, как и прежний редактор. Раскладка готова до показа и в рисовании не участвует: кадр —
/// это видимые полосы, найденные двоичным поиском, поэтому стоимость кадра не зависит от размера документа,
/// а нарисованное всегда полное. Выделение — один кусок плоского текста сцены (`DocumentScene.text`): в таблице
/// оно идёт по ячейкам строка за строкой, а скопированное вставляется в Excel таблицей.
@MainActor
final class DocumentCanvasView: NSView {
    private(set) var scene: DocumentScene = .empty
    /// Отступ сцены от краёв холста.
    var inset: NSSize = SceneStyle.readerInset {
        didSet { if inset != oldValue { needsDisplay = true } }
    }
    /// Решения в «Скрыто»: меняют только цвет меток.
    var decisions = TextDecisions() {
        didSet { if decisions != oldValue { needsDisplay = true; sticky?.needsDisplay = true } }
    }
    /// Пока видны исходные значения (⌥), текст не выделяется: скопировать их случайно нельзя.
    var isTextSelectable = true {
        didSet {
            guard isTextSelectable != oldValue else { return }
            if !isTextSelectable { selection = NSRange(location: 0, length: 0) }
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Текущее выделение в `scene.text`.
    var selection = NSRange(location: 0, length: 0) {
        didSet {
            guard selection != oldValue else { return }
            invalidate(oldValue)
            invalidate(selection)
        }
    }

    /// Метка под курсором мыши (или `nil`).
    var onHoverMark: ((SceneMark?) -> Void)?
    /// Контекстное меню: место в тексте под щелчком (или `nil` — мимо текста).
    var menuProvider: ((_ index: Int?, _ mark: SceneMark?) -> NSMenu?)?

    /// Поиск ⌘F (только в редакторе).
    private(set) var textFinder: NSTextFinder?
    /// Шапка таблицы, которая держится сверху при прокрутке.
    private var sticky: StickyHeaderView?
    private var hovered: SceneMark?
    private var dragAnchor = NSRange(location: 0, length: 0)
    private enum Granularity { case character, word, box }
    private var granularity = Granularity.character

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Рисует только то, что просят: прокрутка вниз дорисовывает новую полосу, а не весь экран.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Обезличенный текст")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    // MARK: Сцена

    /// Новая сцена: тот же документ после правки, другая ширина или другой документ. Прокрутка держится
    /// за полосу, которая была сверху видимой части: правка выше не сдвигает то, что человек читает.
    func setScene(_ next: DocumentScene) {
        let old = scene
        let anchor = topAnchor()
        scene = next
        if old.text != next.text {
            textFinder?.noteClientStringWillChange()
            if NSMaxRange(selection) > next.textLength { selection = NSRange(location: 0, length: 0) }
        }
        updateSize()
        if let anchor, let scroll = enclosingScrollView, old.bands.count == next.bands.count, anchor.band < next.bands.count {
            let band = next.bands[anchor.band]
            let y = inset.height + band.top + min(anchor.offset, band.height)
            let clip = scroll.contentView
            let maxY = max(0, frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), maxY)))
            scroll.reflectScrolledClipView(clip)
        }
        needsDisplay = true
        updateSticky()
    }

    /// Полоса вверху видимой части и где внутри неё край.
    private func topAnchor() -> (band: Int, offset: CGFloat)? {
        guard enclosingScrollView != nil, !scene.bands.isEmpty else { return nil }
        let top = visibleRect.minY
        guard top > 0.5 else { return nil }
        let y = top - inset.height
        let i = min(scene.firstBand(below: y), scene.bands.count - 1)
        return (i, y - scene.bands[i].top)
    }

    /// Размер холста: сцена с отступами, не уже видимой части (в редакторе) — иначе фон и курсор обрываются.
    func updateSize() {
        let width = scene.size.width + inset.width * 2
        let height = scene.size.height + inset.height * 2
        if let clip = enclosingScrollView?.contentView {
            setFrameSize(NSSize(width: max(width, clip.bounds.width), height: max(height, clip.bounds.height)))
        } else {
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: scene.size.height + inset.height * 2)
    }

    /// Точка холста → точка сцены.
    private func scenePoint(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x - inset.width, y: p.y - inset.height) }
    func viewRect(_ r: CGRect) -> NSRect { r.offsetBy(dx: inset.width, dy: inset.height) }

    // MARK: Рисование

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let palette = ScenePalette.current()
            ctx.saveGState()
            ctx.translateBy(x: inset.width, y: inset.height)
            let focused = window?.firstResponder === self && window?.isKeyWindow == true
            ScenePainter.draw(scene, in: dirtyRect.offsetBy(dx: -inset.width, dy: -inset.height), ctx: ctx, palette: palette,
                              state: .init(decisions: decisions, selection: selection, focused: focused))
            ctx.restoreGState()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        sticky?.needsDisplay = true
    }

    /// Перерисовать место куска текста (выделение): большое — всё видимое.
    private func invalidate(_ range: NSRange) {
        guard range.length > 0 else { return }
        if range.length > 20_000 { setNeedsDisplay(visibleRect); return }
        for r in scene.rects(for: range) { setNeedsDisplay(viewRect(r).insetBy(dx: -2, dy: -2)) }
    }

    override func becomeFirstResponder() -> Bool { invalidate(selection); return true }
    override func resignFirstResponder() -> Bool { invalidate(selection); return true }

    // MARK: Мышь

    override func resetCursorRects() {
        if isTextSelectable { addCursorRect(visibleRect, cursor: .iBeam) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        if onHoverMark != nil {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(scene.mark(at: scenePoint(convert(event.locationInWindow, from: nil))))
    }

    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    private func setHovered(_ mark: SceneMark?) {
        let key = mark.flatMap { $0.kind == .restored ? nil : $0 }
        guard key?.key != hovered?.key else { return }
        hovered = key
        onHoverMark?(key)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isTextSelectable, let window else { return }
        let index = scene.index(at: scenePoint(convert(event.locationInWindow, from: nil)))
        switch event.clickCount {
        case 2:
            granularity = .word
            dragAnchor = scene.wordRange(at: index)
        case 3...:
            granularity = .box
            dragAnchor = scene.boxRange(at: index)
        default:
            granularity = .character
            if event.modifierFlags.contains(.shift), selection.location != NSNotFound {
                dragAnchor = NSRange(location: index < selection.location ? NSMaxRange(selection) : selection.location, length: 0)
            } else {
                dragAnchor = NSRange(location: index, length: 0)
            }
        }
        extendSelection(to: index)
        // Своя петля событий: выделение тянется за мышью и прокручивает текст, пока мышь за краем, даже если стоит.
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var last = event
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if next.type == .leftMouseUp { break }
            if next.type == .leftMouseDragged { last = next }
            autoscroll(with: last)
            extendSelection(to: scene.index(at: scenePoint(convert(last.locationInWindow, from: nil))))
        }
    }

    private func extendSelection(to index: Int) {
        let target: NSRange = switch granularity {
        case .character: NSRange(location: index, length: 0)
        case .word: scene.wordRange(at: index)
        case .box: scene.boxRange(at: index)
        }
        let lo = min(dragAnchor.location, target.location), hi = max(NSMaxRange(dragAnchor), NSMaxRange(target))
        selection = NSRange(location: lo, length: hi - lo)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = scenePoint(convert(event.locationInWindow, from: nil))
        let mark = scene.mark(at: p)
        let index = scene.hit(at: p) != nil ? scene.index(at: p) : nil
        return menuProvider?(index, mark)
    }

    // MARK: Клавиатура и буфер обмена

    var selectedText: String {
        guard selection.length > 0, NSMaxRange(selection) <= scene.textLength else { return "" }
        return scene.nsText.substring(with: selection)
    }

    @objc func copy(_ sender: Any?) {
        let text = selectedText.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard isTextSelectable else { return }
        selection = NSRange(location: 0, length: scene.textLength)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return super.keyDown(with: event) }   // Esc — выше: закрыть редактор
        interpretKeyEvents([event])
    }

    override func doCommand(by selector: Selector) {
        if responds(to: selector) { perform(selector, with: nil) } else { super.doCommand(by: selector) }
    }

    private func scroll(by dy: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let maxY = max(0, frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, clip.bounds.minY + dy), maxY)))
        scroll.reflectScrolledClipView(clip)
    }

    private var page: CGFloat { max(40, (enclosingScrollView?.contentView.bounds.height ?? 400) - 60) }

    @objc override func moveUp(_ sender: Any?) { scroll(by: -40) }
    @objc override func moveDown(_ sender: Any?) { scroll(by: 40) }
    @objc override func scrollPageUp(_ sender: Any?) { scroll(by: -page) }
    @objc override func scrollPageDown(_ sender: Any?) { scroll(by: page) }
    @objc override func pageUp(_ sender: Any?) { scroll(by: -page) }
    @objc override func pageDown(_ sender: Any?) { scroll(by: page) }
    @objc override func scrollToBeginningOfDocument(_ sender: Any?) { scroll(by: -frame.height) }
    @objc override func scrollToEndOfDocument(_ sender: Any?) { scroll(by: frame.height) }
    @objc override func moveToBeginningOfDocument(_ sender: Any?) { scroll(by: -frame.height) }
    @objc override func moveToEndOfDocument(_ sender: Any?) { scroll(by: frame.height) }
    @objc override func insertText(_ insertString: Any) {
        // Пробел листает, как в любом просмотре документа.
        if (insertString as? String) == " " { scroll(by: page) }
    }

    // MARK: Найденное

    /// Прокрутить к куску текста: по середине экрана, если он далеко.
    func reveal(_ range: NSRange) {
        let rects = scene.rects(for: range)
        guard let first = rects.first, let scroll = enclosingScrollView else { return }
        let rect = viewRect(rects.dropFirst().reduce(first) { $0.union($1) })
        let clip = scroll.contentView.bounds
        guard !clip.insetBy(dx: 0, dy: 40).contains(rect) else { return }
        let y = rect.midY - clip.height / 2
        let x = rect.maxX > clip.maxX || rect.minX < clip.minX ? max(0, rect.minX - 80) : clip.minX
        let maxY = max(0, frame.height - clip.height)
        scroll.contentView.scroll(to: NSPoint(x: x, y: min(max(0, y), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Найденное из «Скрыто»: выделить, прокрутить и коротко подсветить жёлтым, как индикатор поиска macOS.
    func spotlight(_ range: NSRange) {
        window?.makeFirstResponder(self)
        selection = range
        reveal(range)
        let rects = scene.rects(for: range).map(viewRect)
        guard let first = rects.first else { return }
        let pulse = FindPulse(scene: scene, range: range, rects: rects, inset: inset)
        pulse.frame = rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -4, dy: -2)
        addSubview(pulse)
        pulse.run()
    }

    // MARK: Шапка таблицы сверху

    /// Шапка длинной таблицы держится у верхнего края, пока видны строки этой таблицы, и уезжает вместе с её концом.
    func updateSticky() {
        guard let scroll = enclosingScrollView else { return }
        // Верх видимой части — с отступом области прокрутки: строка поиска ⌘F и панель окна лежат поверх содержимого.
        let top = scroll.contentView.bounds.minY + scroll.contentView.contentInsets.top - inset.height
        var shown: (band: Int, y: CGFloat)?
        if !scene.bands.isEmpty, top > 0 {
            let i = min(scene.firstBand(below: top), scene.bands.count - 1)
            if let row = scene.bands[i].row, let header = scene.tables[row.table].header, header < i || scene.bands[header].top < top {
                let head = scene.bands[header]
                let lastBand = scene.bands[scene.tables[row.table].bands.upperBound - 1]
                let y = min(top, lastBand.bottom - head.height)
                if y > head.top { shown = (header, y) }
            }
        }
        guard let shown else { sticky?.isHidden = true; return }
        let view = sticky ?? {
            let v = StickyHeaderView()
            addSubview(v)
            sticky = v
            return v
        }()
        let band = scene.bands[shown.band]
        let frame = NSRect(x: 0, y: inset.height + shown.y, width: bounds.width, height: band.height)
        if view.frame != frame { view.frame = frame }
        if view.band != shown.band || view.scene !== scene {
            view.scene = scene
            view.band = shown.band
            view.inset = inset
            view.needsDisplay = true
        }
        view.decisions = decisions
        view.isHidden = false
    }

    // MARK: Доступность

    override func accessibilityValue() -> Any? { scene.text }
    override func accessibilityNumberOfCharacters() -> Int { scene.textLength }
    override func accessibilitySelectedText() -> String? { selectedText }
    override func accessibilitySelectedTextRange() -> NSRange { selection }
    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        selection = NSIntersectionRange(range, NSRange(location: 0, length: scene.textLength))
        reveal(selection)
    }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        let r = visibleCharacterRange
        return r
    }
    override func accessibilityString(for range: NSRange) -> String? {
        let r = NSIntersectionRange(range, NSRange(location: 0, length: scene.textLength))
        return scene.nsText.substring(with: r)
    }
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        let rects = scene.rects(for: range)
        guard let first = rects.first, let window else { return .zero }
        let r = convert(viewRect(rects.dropFirst().reduce(first) { $0.union($1) }), to: nil)
        return window.convertToScreen(r)
    }
    override func accessibilityLine(for index: Int) -> Int {
        guard let box = scene.box(containing: index) else { return 0 }
        return scene.band(containing: box) ?? 0
    }
    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard scene.bands.indices.contains(line) else { return NSRange(location: 0, length: 0) }
        let starts = scene.bands[line].boxes.compactMap { scene.boxes[$0].start }
        let ends = scene.bands[line].boxes.compactMap { scene.boxes[$0].end }
        guard let a = starts.min(), let b = ends.max() else { return NSRange(location: 0, length: 0) }
        return NSRange(location: a, length: b - a)
    }
    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let window else { return NSRange(location: 0, length: 0) }
        let p = convert(window.convertPoint(fromScreen: point), from: nil)
        return NSRange(location: scene.index(at: scenePoint(p)), length: 0)
    }

    /// Видимая часть текста (поиск и доступность).
    var visibleCharacterRange: NSRange {
        let rect = visibleRect.offsetBy(dx: -inset.width, dy: -inset.height)
        let bands = scene.bands(in: rect)
        let starts = bands.flatMap { scene.bands[$0].boxes.compactMap { scene.boxes[$0].start } }
        let ends = bands.flatMap { scene.bands[$0].boxes.compactMap { scene.boxes[$0].end } }
        guard let a = starts.min(), let b = ends.max() else { return NSRange(location: 0, length: 0) }
        return NSRange(location: a, length: b - a)
    }

    // MARK: Поиск ⌘F

    func enableFind(in scroll: NSScrollView) {
        let finder = NSTextFinder()
        finder.client = self
        finder.findBarContainer = scroll
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = true
        textFinder = finder
    }

    @objc override func performTextFinderAction(_ sender: Any?) {
        guard let finder = textFinder else { return }
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        finder.performAction(NSTextFinder.Action(rawValue: tag) ?? .showFindInterface)
    }

    @objc func performFindPanelAction(_ sender: Any?) { performTextFinderAction(sender) }
}

extension DocumentCanvasView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): selection.length > 0
        case #selector(selectAll(_:)): isTextSelectable && scene.textLength > 0
        case #selector(performTextFinderAction(_:)), #selector(performFindPanelAction(_:)):
            textFinder.map { $0.validateAction(NSTextFinder.Action(rawValue: item.tag) ?? .showFindInterface) } ?? false
        default: true
        }
    }
}
