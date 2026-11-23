import AppKit

/// Шапка таблицы поверх строк при прокрутке. Рисует одну полосу сцены.
final class StickyHeaderView: NSView {
    weak var scene: DocumentScene?
    var band = -1
    var inset = NSSize.zero
    var decisions = TextDecisions() {
        didSet { if decisions != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let scene, scene.bands.indices.contains(band), let ctx = NSGraphicsContext.current?.cgContext else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let palette = ScenePalette.current()
            ctx.saveGState()
            // Лёгкая тень снизу: шапка лежит поверх строк.
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor.black.withAlphaComponent(0.12).cgColor)
            ctx.translateBy(x: inset.width, y: 0)
            ScenePainter.drawBand(scene, band, dy: -scene.bands[band].top, ctx: ctx, palette: palette, decisions: decisions)
            ctx.restoreGState()
        }
    }
}

/// Мягкий край: содержимое продолжается вправо (широкая таблица). Щелчки проходят насквозь.
final class EdgeFade: NSView {
    static let width: CGFloat = 40
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: color.withAlphaComponent(0), ending: color)?.draw(in: bounds, angle: 0)
    }
}
