import AppKit
import CoreText

/// Разложенный по строкам кусок текста: абзац, ячейка, подпись. CoreText напрямую, без NSTextView.
///
/// Раскладка не зависит ни от главного потока, ни от темы, ни от решений в «Скрыто»: она строится в фоне
/// параллельно для тысяч ячеек (`SceneBuilder`) и переиспользуется, пока не поменялись текст и ширина
/// (`TextLayoutCache`). Строки идут сверху вниз, поэтому видимые находятся двоичным поиском.
final class TextLayout: @unchecked Sendable {
    enum Alignment: Sendable { case left, right }

    struct Line {
        let ct: CTLine
        /// Кусок текста этой строки (UTF-16, в координатах `string`).
        let range: NSRange
        /// Верх строки и базовая линия — от верха куска.
        let top: CGFloat
        let height: CGFloat
        let baseline: CGFloat
        /// Сдвиг строки слева (выравнивание вправо) и ширина без пробелов в конце.
        let x: CGFloat
        let width: CGFloat
    }

    let string: NSAttributedString
    let marks: [SceneMark]
    let lines: [Line]
    let height: CGFloat
    let lineSpacing: CGFloat
    /// Ширина самой длинной строки.
    let usedWidth: CGFloat

    var length: Int { string.length }

    /// `typesetter` — набор букв этого текста, если он уже есть (мера столбцов таблицы): не набирать дважды.
    init(_ styled: SceneText.Styled, width: CGFloat, lineSpacing: CGFloat, alignment: Alignment = .left, font: NSFont,
         typesetter: CTTypesetter? = nil) {
        string = styled.string
        marks = styled.marks
        self.lineSpacing = lineSpacing
        let baseAscent = font.ascender, baseDescent = -font.descender
        let length = string.length
        var lines: [Line] = []
        var y: CGFloat = 0
        var used: CGFloat = 0
        let available = max(Double(width), 1)

        func add(_ ct: CTLine, _ range: NSRange) {
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let total = CGFloat(CTLineGetTypographicBounds(ct, &a, &d, &l))
            let visible = max(0, total - CGFloat(CTLineGetTrailingWhitespaceWidth(ct)))
            let ascent = max(a, baseAscent), descent = max(d, baseDescent)
            let h = ceil(ascent + descent)
            if !lines.isEmpty { y += lineSpacing }
            let x = alignment == .right ? max(0, width - visible) : 0
            lines.append(Line(ct: ct, range: range, top: y, height: h, baseline: y + ceil(ascent), x: x, width: visible))
            used = max(used, visible)
            y += h
        }

        if length == 0 {
            add(CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: [.font: font])), NSRange(location: 0, length: 0))
        } else {
            let typesetter = typesetter ?? CTTypesetterCreateWithAttributedString(string)
            var start = 0
            while start < length {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, available)
                if count <= 0 { count = 1 }
                count = min(count, length - start)
                add(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)), NSRange(location: start, length: count))
                start += count
            }
        }
        self.lines = lines
        height = y
        usedWidth = used
    }

    // MARK: Где что

    /// Первая строка, нижний край которой ниже `y` (двоичный поиск).
    func firstLine(below y: CGFloat) -> Int {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].top + lines[mid].height + lineSpacing <= y { lo = mid + 1 } else { hi = mid }
        }
        return min(lo, max(lines.count - 1, 0))
    }

    /// Место в тексте под точкой (от верха-левого угла куска). Точка выше — начало, ниже — конец.
    func index(at point: CGPoint) -> Int {
        guard !lines.isEmpty else { return 0 }
        if point.y < 0 { return 0 }
        if point.y > height + lineSpacing { return length }
        let line = lines[firstLine(below: point.y)]
        let end = lineEnd(line)
        if point.x <= line.x { return line.range.location }
        let i = CTLineGetStringIndexForPosition(line.ct, CGPoint(x: point.x - line.x, y: 0))
        guard i != kCFNotFound else { return line.range.location }
        return min(max(i, line.range.location), end)
    }

    /// Конец строки без перевода строки: курсор после последней буквы, а не на следующей строке.
    private func lineEnd(_ line: Line) -> Int {
        var end = NSMaxRange(line.range)
        let ns = string.string as NSString
        while end > line.range.location, let c = Optional(ns.character(at: end - 1)), c == 0x0A || c == 0x2028 || c == 0x0D { end -= 1 }
        return end
    }

    func offset(of index: Int, in line: Line) -> CGFloat {
        line.x + CGFloat(CTLineGetOffsetForStringIndex(line.ct, index, nil))
    }

    /// Прямоугольники куска текста (выделение, найденное): по одному на строку.
    func rects(for range: NSRange) -> [CGRect] {
        guard range.length > 0 || length == 0 else { return [] }
        var out: [CGRect] = []
        for (i, line) in lines.enumerated() {
            let lr = line.range
            if lr.location >= NSMaxRange(range) { break }
            if NSMaxRange(lr) <= range.location, !(lr.length == 0 && range.location == lr.location) { continue }
            let startsHere = range.location > lr.location
            let endsHere = NSMaxRange(range) < NSMaxRange(lr)
            let x0 = startsHere ? offset(of: range.location, in: line) : line.x
            var x1 = endsHere ? offset(of: NSMaxRange(range), in: line) : line.x + line.width
            // Выделение через конец строки захватывает и место переноса — как в любом тексте macOS.
            if !endsHere, NSMaxRange(range) > NSMaxRange(lr) || lineEnd(line) < NSMaxRange(lr) { x1 += 4 }
            let gap = i < lines.count - 1 ? lineSpacing : 0
            out.append(CGRect(x: x0, y: line.top, width: max(x1 - x0, 2), height: line.height + gap))
        }
        return out
    }

    /// Отметки, которые касаются места `index` (метка под курсором мыши).
    func mark(at index: Int) -> SceneMark? {
        marks.first { NSLocationInRange(index, $0.range) }
    }

    // MARK: Рисование

    /// Рисует строки, попадающие в `clip` (координаты контекста). `origin` — верх-левый угол куска.
    /// Контекст перевёрнут (y вниз), текстовая матрица — `ScenePainter.prepare`.
    func draw(in ctx: CGContext, at origin: CGPoint, clip: CGRect, palette: ScenePalette, decisions: TextDecisions) {
        guard !lines.isEmpty, origin.y + height >= clip.minY, origin.y <= clip.maxY else { return }
        var i = firstLine(below: clip.minY - origin.y)
        while i < lines.count {
            let line = lines[i]
            if origin.y + line.top > clip.maxY { break }
            if !marks.isEmpty { drawPills(line, at: origin, in: ctx, palette: palette, decisions: decisions) }
            drawRuns(line, at: origin, in: ctx, palette: palette, decisions: decisions)
            i += 1
        }
    }

    private func drawRuns(_ line: Line, at origin: CGPoint, in ctx: CGContext, palette: ScenePalette, decisions: TextDecisions) {
        let runs = CTLineGetGlyphRuns(line.ct) as! [CTRun]
        for run in runs {
            let r = CTRunGetStringRange(run)
            var color: CGColor
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let role = (attrs[SceneKey.role] as? Int).flatMap(SceneRole.init(rawValue:)) ?? .text
            color = palette.color(for: role)
            if !marks.isEmpty, let m = mark(at: r.location) {
                switch m.kind {
                case .tag, .shown: color = decisions.isHidden(m.key) ? palette.accent : palette.secondary
                case .peek: color = palette.accent
                case .restored: break
                }
            }
            ctx.setFillColor(color)
            ctx.textPosition = CGPoint(x: origin.x + line.x, y: origin.y + line.baseline)
            CTRunDraw(run, ctx, CFRange(location: 0, length: 0))
        }
    }

    private func drawPills(_ line: Line, at origin: CGPoint, in ctx: CGContext, palette: ScenePalette, decisions: TextDecisions) {
        let kern = SceneStyle.pillGap
        for m in marks {
            let lo = max(m.range.location, line.range.location), hi = min(NSMaxRange(m.range), NSMaxRange(line.range))
            if m.range.location >= NSMaxRange(line.range) { break }
            guard lo < hi else { continue }
            let font = string.attribute(.font, at: lo, effectiveRange: nil) as? NSFont ?? SceneStyle.bodyFont
            var x0 = offset(of: lo, in: line), x1 = offset(of: hi, in: line)
            if lo == m.range.location { x0 -= SceneStyle.pillOutset }
            if hi == NSMaxRange(m.range) { x1 += SceneStyle.pillOutset - kern }
            let ascent = font.ascender, descent = -font.descender
            let rect = CGRect(x: origin.x + x0, y: origin.y + line.baseline - ascent - 2, width: x1 - x0, height: ascent + descent + 4)
            let fill: CGColor
            switch m.kind {
            case .tag, .shown: fill = decisions.isHidden(m.key) ? palette.accentSoft : palette.mutedSoft
            case .peek: fill = palette.accentSoft
            case .restored: fill = palette.restoredSoft
            }
            ctx.setFillColor(fill)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: SceneStyle.pillRadius, cornerHeight: SceneStyle.pillRadius, transform: nil))
            ctx.fillPath()
        }
    }
}

/// Готовые раскладки по тексту, оформлению и ширине: правка в «Скрыто» меняет несколько ячеек — раскладываются
/// только они. Хранит два поколения: текущее и предыдущее (⌥ туда-обратно не раскладывает документ заново).
final class TextLayoutCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        var text: String
        var marks: [SceneMark]
        var style: Int
        var width: CGFloat
    }

    private let lock = NSLock()
    private var current: [Key: TextLayout] = [:]
    private var previous: [Key: TextLayout] = [:]
    /// Меры ячеек для ширины столбцов (от ширины не зависят; ключ — с шириной 0).
    private var measures: [Key: ColumnWidths.Measure] = [:]
    private var previousMeasures: [Key: ColumnWidths.Measure] = [:]

    func measure(_ key: Key) -> ColumnWidths.Measure? {
        lock.lock(); defer { lock.unlock() }
        if let hit = measures[key] { return hit }
        if let hit = previousMeasures[key] { measures[key] = hit; return hit }
        return nil
    }

    func put(_ key: Key, _ measure: ColumnWidths.Measure) {
        lock.lock(); defer { lock.unlock() }
        measures[key] = measure
    }

    init() {}

    func get(_ key: Key) -> TextLayout? {
        lock.lock(); defer { lock.unlock() }
        if let hit = current[key] { return hit }
        if let hit = previous[key] { current[key] = hit; return hit }
        return nil
    }

    func put(_ key: Key, _ layout: TextLayout) {
        lock.lock(); defer { lock.unlock() }
        current[key] = layout
        made += 1
    }

    /// Сколько кусков разложено заново за всё время (проверка: правка раскладывает только изменённое).
    private(set) var made = 0

    /// Новое поколение: то, что не понадобилось в последней сборке, уходит.
    func rotate() {
        lock.lock(); defer { lock.unlock() }
        previous = current
        current = [:]
        previousMeasures = measures
        measures = [:]
    }
}
