import AppKit

/// Разложенный документ: всё, что нужно, чтобы нарисовать любую полосу, попасть мышью в букву и найти текст.
///
/// Документ — последовательность полос (`Band`) сверху вниз: абзац, строка таблицы, подпись, строка кода.
/// Полосы не перекрываются и идут по возрастанию `y`, поэтому полоса под любой точкой находится двоичным поиском,
/// а нарисовать кадр — значит нарисовать только видимые полосы. Ничего не раскладывается «потом» и ничего не
/// теряется при рисовании: всё положено на место до показа (`SceneBuilder`).
///
/// Текст для выделения, копирования и поиска — `text`: все куски подряд, ячейки строки через табуляцию,
/// строки и абзацы через перевод строки. Скопированный кусок таблицы вставляется в Excel таблицей.
/// Служебный текст вида (подписи разделов, номера строк, маркеры списков) в него не входит.
final class DocumentScene: @unchecked Sendable {
    /// Кусок текста на месте.
    struct Box {
        let layout: TextLayout
        /// Левый верхний угол текста (в координатах сцены).
        var origin: CGPoint
        /// Где начинается в `text`; `nil` — служебный текст, не выделяется.
        let start: Int?
        var end: Int? { start.map { $0 + layout.length } }
        var frame: CGRect { CGRect(x: origin.x, y: origin.y, width: max(layout.usedWidth, 1), height: layout.height) }
    }

    /// Строка таблицы: фон, сетка.
    struct Row {
        let table: Int
        let header: Bool
        /// Границы ячеек слева направо (первая — левый край таблицы, последняя — правый).
        let edges: [CGFloat]
        /// Правый край столбца номеров строк (лист).
        let labelEdge: CGFloat?
        let first: Bool
    }

    struct Band {
        var top: CGFloat
        var height: CGFloat
        /// Куски текста полосы — подряд в `boxes`.
        var boxes: Range<Int>
        var row: Row?
        var bottom: CGFloat { top + height }
    }

    /// Подложка под несколько полос: карточка слайда, код, пометка, поля письма, линия служебной части, полоса цитаты.
    struct Frame {
        enum Fill: Sendable { case card, code, note, header }
        enum Kind { case card(fill: Fill, stroke: Bool, radius: CGFloat), rule, bar }
        let kind: Kind
        var rect: CGRect
    }

    struct Table {
        /// Полосы таблицы и полоса шапки (для шапки, которая держится сверху при прокрутке).
        var bands: Range<Int>
        var header: Int?
    }

    let bands: [Band]
    let boxes: [Box]
    let frames: [Frame]
    let tables: [Table]
    /// Текст для выделения, копирования и поиска. `nsText` — он же для работы по местам UTF-16 (выделение, слово под
    /// курсором): у Swift-строки с кириллицей каждое такое обращение — перекодировка.
    let text: String
    let nsText: NSString
    let textLength: Int
    /// Номера кусков, у которых есть место в `text`, по порядку — для поиска куска по месту в тексте.
    private let selectable: [Int]
    let size: CGSize

    init(bands: [Band], boxes: [Box], frames: [Frame], tables: [Table], text: String, size: CGSize) {
        self.bands = bands
        self.boxes = boxes
        self.frames = frames
        self.tables = tables
        self.text = text
        nsText = NSString(string: text)
        textLength = nsText.length
        selectable = boxes.indices.filter { boxes[$0].start != nil }
        self.size = size
    }

    static let empty = DocumentScene(bands: [], boxes: [], frames: [], tables: [], text: "", size: .zero)

    // MARK: Полосы

    /// Первая полоса, нижний край которой ниже `y`.
    func firstBand(below y: CGFloat) -> Int {
        var lo = 0, hi = bands.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if bands[mid].bottom <= y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Полосы, которые касаются прямоугольника по вертикали.
    func bands(in rect: CGRect) -> Range<Int> {
        let a = firstBand(below: rect.minY)
        var b = a
        while b < bands.count, bands[b].top <= rect.maxY { b += 1 }
        return a..<b
    }

    // MARK: Текст ↔ место

    /// Номер в `selectable` куска, в котором стоит место `index` текста (двоичный поиск).
    private func position(containing index: Int) -> Int? {
        guard !selectable.isEmpty else { return nil }
        var lo = 0, hi = selectable.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if let end = boxes[selectable[mid]].end, end < index { lo = mid + 1 } else { hi = mid }
        }
        return min(lo, selectable.count - 1)
    }

    /// Кусок, в котором стоит место `index` текста.
    func box(containing index: Int) -> Int? { position(containing: index).map { selectable[$0] } }

    /// Выделяемые куски, которые пересекают кусок текста.
    func boxes(for range: NSRange) -> [Int] {
        guard let first = position(containing: range.location) else { return [] }
        var out: [Int] = []
        for i in selectable[first...] {
            guard let start = boxes[i].start else { continue }
            if start > NSMaxRange(range) || (start == NSMaxRange(range) && range.length > 0) { break }
            out.append(i)
        }
        return out
    }

    /// Прямоугольники куска текста в координатах сцены.
    func rects(for range: NSRange) -> [CGRect] {
        var out: [CGRect] = []
        for i in boxes(for: range) {
            let b = boxes[i]
            guard let start = b.start else { continue }
            let local = NSIntersectionRange(range, NSRange(location: start, length: b.layout.length))
            let r = local.length > 0 || range.length == 0
                ? NSRange(location: local.location - start, length: local.length)
                : NSRange(location: 0, length: 0)
            if r.length == 0, range.length > 0 { continue }
            out += b.layout.rects(for: r).map { $0.offsetBy(dx: b.origin.x, dy: b.origin.y) }
        }
        return out
    }

    /// Место в тексте под точкой сцены: полоса по `y`, кусок по `x`, буква — CoreText.
    /// Между кусками — ближайший; служебный текст — соседний выделяемый.
    func index(at point: CGPoint) -> Int {
        guard !bands.isEmpty else { return 0 }
        if point.y < 0 { return 0 }
        let here = min(firstBand(below: point.y), bands.count - 1)
        func pick(_ band: Band) -> Int? {
            band.boxes.filter { boxes[$0].start != nil }.min { distance(point.x, boxes[$0]) < distance(point.x, boxes[$1]) }
        }
        if let i = pick(bands[here]) {
            let b = boxes[i]
            return (b.start ?? 0) + b.layout.index(at: CGPoint(x: point.x - b.origin.x, y: point.y - b.origin.y))
        }
        // Полоса без выделяемого текста (подпись раздела): начало следующего текста, а в конце документа — конец предыдущего.
        for j in (here + 1)..<bands.count { if let i = pick(bands[j]) { return boxes[i].start ?? 0 } }
        for j in stride(from: here - 1, through: 0, by: -1) { if let i = pick(bands[j]) { return boxes[i].end ?? 0 } }
        return 0
    }

    private func distance(_ x: CGFloat, _ box: Box) -> CGFloat {
        let f = box.frame
        let right = max(f.maxX, f.minX + 1)
        if x < f.minX { return f.minX - x }
        if x > right { return x - right }
        return 0
    }

    /// Кусок и место в нём под точкой — только если точка над самим текстом (метка под курсором мыши).
    func hit(at point: CGPoint) -> (box: Int, local: Int)? {
        guard !bands.isEmpty else { return nil }
        let bandIndex = firstBand(below: point.y)
        guard bandIndex < bands.count, bands[bandIndex].top <= point.y else { return nil }
        for i in bands[bandIndex].boxes {
            let b = boxes[i]
            guard b.frame.insetBy(dx: -SceneStyle.pillOutset, dy: 0).contains(point) else { continue }
            let p = CGPoint(x: point.x - b.origin.x, y: point.y - b.origin.y)
            return (i, b.layout.index(at: p))
        }
        return nil
    }

    /// Отметка (метка, открытое значение) под точкой.
    func mark(at point: CGPoint) -> SceneMark? {
        guard let (i, local) = hit(at: point) else { return nil }
        let layout = boxes[i].layout
        return layout.marks.first { m in
            NSLocationInRange(local, m.range) || (local == NSMaxRange(m.range) && local > 0 && layout.rects(for: m.range).contains {
                $0.offsetBy(dx: boxes[i].origin.x, dy: boxes[i].origin.y).insetBy(dx: -SceneStyle.pillOutset, dy: 0).contains(point)
            })
        }
    }

    /// Отметка в месте текста (контекстное меню).
    func mark(atText index: Int) -> SceneMark? {
        guard let i = box(containing: index), let start = boxes[i].start else { return nil }
        let local = index - start
        return boxes[i].layout.marks.first { NSLocationInRange(local, $0.range) }
    }

    /// Ширина слова под местом (двойной щелчок): буквы и цифры, метка целиком.
    func wordRange(at index: Int) -> NSRange {
        let ns = nsText
        guard index < textLength else { return NSRange(location: index, length: 0) }
        if let m = mark(atText: index), let i = box(containing: index), let start = boxes[i].start {
            return NSRange(location: start + m.range.location, length: m.range.length)
        }
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-'’"))
        func isWord(_ i: Int) -> Bool { UnicodeScalar(ns.character(at: i)).map(word.contains) ?? true }
        guard isWord(index) else { return NSRange(location: index, length: 1) }
        var a = index, b = index
        while a > 0, isWord(a - 1) { a -= 1 }
        while b < textLength, isWord(b) { b += 1 }
        return NSRange(location: a, length: b - a)
    }

    /// Ячейка или абзац под местом (тройной щелчок).
    func boxRange(at index: Int) -> NSRange {
        guard let i = box(containing: index), let start = boxes[i].start else { return NSRange(location: index, length: 0) }
        return NSRange(location: start, length: boxes[i].layout.length)
    }

    /// Полоса, в которой стоит место текста (прокрутка к найденному).
    func band(containing box: Int) -> Int? {
        var lo = 0, hi = bands.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if bands[mid].boxes.upperBound <= box { lo = mid + 1 } else { hi = mid }
        }
        return lo < bands.count ? lo : nil
    }
}
