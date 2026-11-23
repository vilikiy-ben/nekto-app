import AppKit

/// Рисует часть сцены в перевёрнутый контекст (y вниз): подложки, сетку таблиц, выделение, текст с «пилюлями».
///
/// Только то, что касается прямоугольника, — с запасом `overhang`: «пилюля» метки и хвосты букв выходят
/// за свою строку на пару точек, и полоса, нарисованная отдельно от соседней (плитки слоя AppKit), не должна их резать.
/// Это и было причиной пустых полос у прежнего вида: TextKit 1 искал, что рисовать, по строкам текста, а строки
/// таблицы идут не по возрастанию высоты (`docs/ARCHITECTURE.md` → «Интерфейс»). Здесь полосы монотонны по построению.
enum ScenePainter {
    static let overhang: CGFloat = 8

    struct State {
        var decisions = TextDecisions()
        var selection = NSRange(location: NSNotFound, length: 0)
        var focused = true
    }

    /// Текстовая матрица для перевёрнутого контекста: CoreText рисует буквы головой вверх.
    static func prepare(_ ctx: CGContext) {
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    }

    static func draw(_ scene: DocumentScene, in rect: CGRect, ctx: CGContext, palette: ScenePalette, state: State) {
        prepare(ctx)
        let area = rect.insetBy(dx: -overhang, dy: -overhang)
        for frame in scene.frames where frame.rect.intersects(area) { drawFrame(frame, ctx: ctx, palette: palette) }
        let visible = scene.bands(in: area)
        for i in visible {
            if let row = scene.bands[i].row { drawRowChrome(scene.bands[i], row, ctx: ctx, palette: palette, dy: 0) }
        }
        if state.selection.location != NSNotFound, state.selection.length > 0 {
            ctx.setFillColor(state.focused ? palette.selection : palette.selectionInactive)
            for i in visible {
                for b in scene.bands[i].boxes {
                    let box = scene.boxes[b]
                    guard let start = box.start else { continue }
                    let local = NSIntersectionRange(state.selection, NSRange(location: start, length: box.layout.length + 1))
                    guard local.length > 0 else { continue }
                    let r = NSRange(location: local.location - start, length: local.length)
                    for rect in box.layout.rects(for: r) { ctx.fill(rect.offsetBy(dx: box.origin.x, dy: box.origin.y)) }
                }
            }
        }
        for i in visible {
            for b in scene.bands[i].boxes {
                let box = scene.boxes[b]
                box.layout.draw(in: ctx, at: box.origin, clip: area, palette: palette, decisions: state.decisions)
            }
        }
    }

    /// Одна полоса со сдвигом по вертикали — шапка таблицы, которая держится сверху при прокрутке.
    static func drawBand(_ scene: DocumentScene, _ index: Int, dy: CGFloat, ctx: CGContext, palette: ScenePalette, decisions: TextDecisions) {
        prepare(ctx)
        let band = scene.bands[index]
        if let row = band.row { drawRowChrome(band, row, ctx: ctx, palette: palette, dy: dy, sticky: true) }
        for b in band.boxes {
            let box = scene.boxes[b]
            let origin = CGPoint(x: box.origin.x, y: box.origin.y + dy)
            box.layout.draw(in: ctx, at: origin, clip: .infinite, palette: palette, decisions: decisions)
        }
    }

    // MARK: Подложки и сетка

    private static func drawFrame(_ frame: DocumentScene.Frame, ctx: CGContext, palette: ScenePalette) {
        let r = frame.rect
        switch frame.kind {
        case .card(let fill, let stroke, let radius):
            let color: CGColor = switch fill {
            case .card: palette.cardFill
            case .code: palette.codeFill
            case .note: palette.noteFill
            case .header: palette.headerFill
            }
            let path = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.setFillColor(color)
            ctx.addPath(path)
            ctx.fillPath()
            if stroke {
                ctx.setStrokeColor(palette.line)
                ctx.setLineWidth(1)
                ctx.addPath(path)
                ctx.strokePath()
            }
        case .rule:
            ctx.setFillColor(palette.grid)
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 1))
        case .bar:
            ctx.setFillColor(palette.grid)
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX, y: r.minY, width: 3, height: r.height), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.fillPath()
        }
    }

    private static func drawRowChrome(_ band: DocumentScene.Band, _ row: DocumentScene.Row, ctx: CGContext, palette: ScenePalette, dy: CGFloat,
                                      sticky: Bool = false) {
        guard let left = row.edges.first, let right = row.edges.last else { return }
        let top = band.top + dy, bottom = band.bottom + dy
        let line = SceneStyle.hairline
        if sticky {
            // Шапка поверх строк: непрозрачная, иначе сквозь неё видны строки под ней.
            ctx.setFillColor(palette.canvas)
            ctx.fill(CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
        if row.header {
            ctx.setFillColor(palette.headerFill)
            ctx.fill(CGRect(x: left, y: top, width: right - left, height: bottom - top))
        } else if let labelEdge = row.labelEdge {
            ctx.setFillColor(palette.labelFill)
            ctx.fill(CGRect(x: left, y: top, width: labelEdge - left, height: bottom - top))
        }
        ctx.setFillColor(palette.grid)
        if row.first || sticky { ctx.fill(CGRect(x: left, y: top, width: right - left, height: line)) }
        ctx.fill(CGRect(x: left, y: bottom - line, width: right - left, height: line))
        for (i, x) in row.edges.enumerated() {
            let lx = i == row.edges.count - 1 ? x - line : x
            ctx.fill(CGRect(x: lx, y: top, width: line, height: bottom - top))
        }
    }
}
