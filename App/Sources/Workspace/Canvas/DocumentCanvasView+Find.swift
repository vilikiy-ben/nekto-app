import AppKit

/// Поиск ⌘F по холсту: `NSTextFinder` работает с плоским текстом сцены, как с текстом NSTextView, —
/// строка поиска системы, счётчик, затемнение и подсветка найденного. И вспышка над найденным из «Скрыто».
extension DocumentCanvasView: @preconcurrency NSTextFinderClient {
    var string: String { scene.text }
    func stringLength() -> Int { scene.textLength }
    var isSelectable: Bool { isTextSelectable }
    var allowsMultipleSelection: Bool { false }
    var isEditable: Bool { false }

    var firstSelectedRange: NSRange { selection }

    var selectedRanges: [NSValue] {
        get { [NSValue(range: selection)] }
        set { selection = newValue.first?.rangeValue ?? NSRange(location: 0, length: 0) }
    }

    func scrollRangeToVisible(_ range: NSRange) { reveal(range) }

    var visibleCharacterRanges: [NSValue] { [NSValue(range: visibleCharacterRange)] }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        scene.rects(for: range).map { NSValue(rect: viewRect($0)) }
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        outRange.pointee = NSRange(location: 0, length: scene.textLength)
        return self
    }

    /// Найденное поверх затемнения и на жёлтой плашке: буквы этого куска, без фона, тёмные в любой теме — как у системы.
    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        (NSAppearance(named: .aqua) ?? effectiveAppearance).performAsCurrentDrawingAppearance {
            let palette = ScenePalette.ink(CGColor(gray: 0.1, alpha: 1))
            ctx.saveGState()
            let clips = scene.rects(for: range).map(viewRect)
            ctx.clip(to: clips)
            ctx.translateBy(x: inset.width, y: inset.height)
            ScenePainter.prepare(ctx)
            for i in scene.boxes(for: range) {
                let box = scene.boxes[i]
                box.layout.draw(in: ctx, at: box.origin, clip: .infinite, palette: palette, decisions: decisions)
            }
            ctx.restoreGState()
        }
    }
}

/// Жёлтая плашка над найденным, как `showFindIndicator` у NSTextView: найденный текст тёмным на жёлтом,
/// подпрыгивает и гаснет.
final class FindPulse: NSView {
    private let scene: DocumentScene
    private let range: NSRange
    private let rects: [NSRect]
    private let inset: NSSize

    init(scene: DocumentScene, range: NSRange, rects: [NSRect], inset: NSSize) {
        self.scene = scene
        self.range = range
        self.rects = rects
        self.inset = inset
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Текст на жёлтом — всегда тёмный, как у системы, в любой теме.
        (NSAppearance(named: .aqua) ?? effectiveAppearance).performAsCurrentDrawingAppearance {
            let palette = ScenePalette.ink(CGColor(gray: 0.1, alpha: 1))
            ctx.saveGState()
            ctx.translateBy(x: -frame.minX, y: -frame.minY)
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(NSColor.findHighlightColor.cgColor)
            let plates = rects.map { $0.insetBy(dx: -3, dy: -1) }
            for r in plates {
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
            }
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            // Только найденное: остальной текст ячейки светлыми буквами поверх тёмной темы выглядел бы негативом.
            ctx.clip(to: plates)
            ctx.translateBy(x: inset.width, y: inset.height)
            ScenePainter.prepare(ctx)
            for i in scene.boxes(for: range) {
                let box = scene.boxes[i]
                box.layout.draw(in: ctx, at: box.origin, clip: .infinite, palette: palette, decisions: TextDecisions())
            }
            ctx.restoreGState()
        }
    }

    func run() {
        guard let layer else { return }
        // Масштаб вокруг середины: у слоя вида AppKit точка привязки — угол, её не трогаем.
        let w = bounds.width / 2, h = bounds.height / 2
        func scaled(_ k: CGFloat) -> NSValue {
            NSValue(caTransform3D: CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(w, h, 0), k, k, 1), -w, -h, 0))
        }
        let bounce = CAKeyframeAnimation(keyPath: "transform")
        bounce.values = [scaled(1), scaled(1.2), scaled(1)]
        bounce.duration = 0.25
        layer.add(bounce, forKey: "bounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.removeFromSuperview() }
            })
        }
    }
}
