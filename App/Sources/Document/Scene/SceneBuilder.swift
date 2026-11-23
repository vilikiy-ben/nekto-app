import AppKit

/// Вид документа (`DocumentLayout`) → разложенная сцена (`DocumentScene`). Без интерфейса и не на главном потоке.
///
/// Три прохода:
/// 1. **Форма** — обход блоков: какие полосы, какие куски текста в них, где подложки, ширина столбцов таблиц.
///    Тексты ячеек оформляются (метки, открытые значения, ⌥) и меряются параллельно.
/// 2. **Раскладка** — каждый кусок текста раскладывается CoreText по строкам, параллельно на всех ядрах.
///    Готовые раскладки берутся из кеша (`TextLayoutCache`): после правки в «Скрыто» заново — только изменившиеся ячейки.
/// 3. **Место** — полосы ставятся сверху вниз; высота строки таблицы — по самой высокой ячейке.
///
/// Отступы и шрифты — как у прежнего вида на NSTextView (`SceneStyle`): документ выглядит так же, только
/// раскладывается и рисуется своим кодом.
struct SceneBuilder: Sendable {
    struct Options: Sendable, Equatable {
        /// Ширина текста (без отступов редактора).
        var width: CGFloat
        /// Карточка в ленте: мельче отступы у слайдов.
        var inline = false
        var text = SceneTextOptions()
    }

    let options: Options
    let cache: TextLayoutCache

    init(options: Options, cache: TextLayoutCache = TextLayoutCache()) {
        self.options = options
        self.cache = cache
    }

    func build(_ layout: DocumentLayout) -> DocumentScene {
        cache.rotate()
        var form = Form(options: options, cache: cache)
        form.emit(layout.blocks, context: .init(x: 0, width: options.width))
        let layouts = typeset(form.boxes)
        return place(form, layouts)
    }

    // MARK: Раскладка

    /// Одинаковые куски (название магазина в каждой строке листа) раскладываются один раз; готовые — из кеша.
    private func typeset(_ pending: [PendingBox]) -> [TextLayout] {
        var unique: [TextLayoutCache.Key: Int] = [:]
        var slot = [Int](repeating: 0, count: pending.count)
        var keys: [TextLayoutCache.Key] = []
        var firsts: [Int] = []
        for (i, p) in pending.enumerated() {
            let key = TextLayoutCache.Key(text: p.styled.string.string, marks: p.styled.marks, style: p.style, width: p.width)
            if let k = unique[key] {
                slot[i] = k
            } else {
                unique[key] = keys.count
                slot[i] = keys.count
                keys.append(key)
                firsts.append(i)
            }
        }
        var made = [TextLayout?](repeating: nil, count: keys.count)
        let cache = self.cache
        let uniqueKeys = keys, firstOf = firsts
        made.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let target = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: max(1, (uniqueKeys.count + 63) / 64)) { chunk in
                for k in (chunk * 64)..<min(chunk * 64 + 64, uniqueKeys.count) {
                    if let hit = cache.get(uniqueKeys[k]) {
                        target[k] = hit
                        continue
                    }
                    let p = pending[firstOf[k]]
                    let layout = TextLayout(p.styled, width: p.width, lineSpacing: p.lineSpacing, alignment: p.alignment, font: p.font,
                                            typesetter: p.typesetter)
                    cache.put(uniqueKeys[k], layout)
                    target[k] = layout
                }
            }
        }
        return slot.map { made[$0]! }
    }

    // MARK: Место

    private func place(_ form: Form, _ layouts: [TextLayout]) -> DocumentScene {
        var bands: [DocumentScene.Band] = []
        var boxes: [DocumentScene.Box] = []
        var frames = form.frames.map { DocumentScene.Frame(kind: $0.kind, rect: CGRect(x: $0.x, y: 0, width: $0.width, height: 0)) }
        var tables = form.tables.map { _ in DocumentScene.Table(bands: 0..<0, header: nil) }
        boxes.reserveCapacity(form.boxes.count)
        bands.reserveCapacity(form.items.count)
        var y: CGFloat = 0
        var pendingAfter: CGFloat = 0
        var first = true
        for item in form.items {
            switch item {
            case .open(let f, let margin, let padding):
                y += (first ? 0 : pendingAfter + margin)
                pendingAfter = 0
                frames[f].rect.origin.y = y
                y += padding
                first = false
            case .close(let f, let padding, let margin):
                // Отступ после последнего абзаца внутри подложки не нужен: снизу её держит свой отступ.
                y += padding
                frames[f].rect.size.height = y - frames[f].rect.minY
                pendingAfter = margin
            case .band(let b):
                y += first ? 0 : pendingAfter + b.before
                first = false
                var content: CGFloat = b.minHeight
                for i in b.boxes { content = max(content, form.boxes[i].dy + layouts[i].height) }
                let start = boxes.count
                for i in b.boxes {
                    let p = form.boxes[i]
                    boxes.append(DocumentScene.Box(layout: layouts[i], origin: CGPoint(x: p.dx, y: y + b.padTop + p.dy), start: p.start))
                }
                let height = b.padTop + content + b.padBottom
                if let row = b.row {
                    let index = bands.count
                    if tables[row.table].bands.isEmpty { tables[row.table].bands = index..<index }
                    tables[row.table].bands = tables[row.table].bands.lowerBound..<(index + 1)
                    if row.header { tables[row.table].header = index }
                }
                bands.append(DocumentScene.Band(top: y, height: height, boxes: start..<boxes.count, row: b.row))
                y += height
                pendingAfter = b.after
            }
        }
        let width = max(options.width, form.required)
        return DocumentScene(bands: bands, boxes: boxes, frames: frames, tables: tables, text: form.text as String,
                             size: CGSize(width: ceil(width), height: ceil(y)))
    }
}

// MARK: - Форма документа

/// Кусок текста до раскладки.
private struct PendingBox: @unchecked Sendable {
    var styled: SceneText.Styled
    var width: CGFloat
    var lineSpacing: CGFloat
    var alignment: TextLayout.Alignment
    var font: NSFont
    /// Оформление — часть ключа кеша.
    var style: Int
    var dx: CGFloat
    var dy: CGFloat
    var start: Int?
    /// Набор букв, оставшийся от меры столбцов.
    var typesetter: CTTypesetter?
}

private struct PendingBand {
    var before: CGFloat
    var after: CGFloat
    var padTop: CGFloat = 0
    var padBottom: CGFloat = 0
    var minHeight: CGFloat = 0
    var boxes: Range<Int>
    var row: DocumentScene.Row?
}

private enum Item {
    case band(PendingBand)
    case open(frame: Int, margin: CGFloat, padding: CGFloat)
    case close(frame: Int, padding: CGFloat, margin: CGFloat)
}

private struct PendingFrame {
    var kind: DocumentScene.Frame.Kind
    var x: CGFloat
    var width: CGFloat
}

/// Обход блоков документа. Повторяет правила отступов прежнего вида: после заголовка — вплотную,
/// после таблицы и раздела — 12, между абзацами — 6 + 6.
private struct Form {
    struct Context {
        var x: CGFloat
        var width: CGFloat
        var muted = false
        var inTable = false
    }

    enum Previous { case start, heading, text, item, table, section }

    enum Style: Int {
        case body, heading1, heading2, heading3, cell, header, label, caption, code, note, fieldLabel, fieldValue, marker, more, quote
    }

    let options: SceneBuilder.Options
    let cache: TextLayoutCache
    let matcher: ShownMatcher?
    var items: [Item] = []
    var boxes: [PendingBox] = []
    var frames: [PendingFrame] = []
    var tables: [Int] = []
    let text = NSMutableString()
    var required: CGFloat = 0
    var previous: Previous = .start

    init(options: SceneBuilder.Options, cache: TextLayoutCache) {
        self.options = options
        self.cache = cache
        matcher = options.text.replies ? nil : ShownMatcher(options.text.shown)
    }

    // MARK: Куски текста

    private func styled(_ raw: String, _ font: NSFont, _ role: SceneRole, chrome: Bool = false) -> SceneText.Styled {
        SceneText.make(raw, font: font, role: role, chrome: chrome, options: options.text, matcher: matcher)
    }

    /// Кусок текста в очередь раскладки. `selectable` — содержимое документа (идёт в `text`).
    private mutating func box(_ s: SceneText.Styled, style: Style, role: SceneRole, font: NSFont, width: CGFloat, dx: CGFloat, dy: CGFloat = 0,
                              lineSpacing: CGFloat, alignment: TextLayout.Alignment = .left, selectable: Bool,
                              separator: String = "\n", typesetter: CTTypesetter? = nil) -> Int {
        var start: Int?
        if selectable {
            start = text.length
            text.append(s.string.string)
            text.append(separator)
        }
        boxes.append(PendingBox(styled: s, width: max(width, 8), lineSpacing: lineSpacing, alignment: alignment, font: font,
                                style: Self.styleKey(style, role, alignment), dx: dx, dy: dy, start: start, typesetter: typesetter))
        return boxes.count - 1
    }

    static func styleKey(_ style: Style, _ role: SceneRole, _ alignment: TextLayout.Alignment = .left) -> Int {
        style.rawValue * 16 + role.rawValue * 2 + (alignment == .right ? 1 : 0)
    }

    private mutating func band(_ boxes: Range<Int>, before: CGFloat, after: CGFloat, padTop: CGFloat = 0, padBottom: CGFloat = 0,
                               row: DocumentScene.Row? = nil) {
        items.append(.band(PendingBand(before: before, after: after, padTop: padTop, padBottom: padBottom, boxes: boxes, row: row)))
    }

    private mutating func open(_ kind: DocumentScene.Frame.Kind, context: Context, margin: CGFloat, padding: CGFloat) -> Int {
        frames.append(PendingFrame(kind: kind, x: context.x, width: context.width))
        items.append(.open(frame: frames.count - 1, margin: margin, padding: padding))
        return frames.count - 1
    }

    private mutating func close(_ frame: Int, padding: CGFloat, margin: CGFloat) {
        items.append(.close(frame: frame, padding: padding, margin: margin))
    }

    /// Абзац прозы на всю ширину контекста.
    private mutating func paragraph(_ raw: String, style: Style, font: NSFont, role: SceneRole, context: Context, before: CGFloat, after: CGFloat,
                                    lineSpacing: CGFloat = SceneStyle.proseLineSpacing, indent: CGFloat = 0) {
        let i = box(styled(raw, font, role), style: style, role: role, font: font, width: context.width - indent, dx: context.x + indent,
                    lineSpacing: lineSpacing, selectable: true)
        band(i..<(i + 1), before: before, after: after)
    }

    private var spacing: CGFloat {
        switch previous {
        case .start, .heading: 0
        case .table, .section: 12
        default: 6
        }
    }

    private func role(_ context: Context, muted: Bool = false) -> SceneRole { context.muted || muted ? .secondary : .text }

    // MARK: Блоки

    mutating func emit(_ blocks: [DocBlock], context: Context) {
        for block in blocks { emit(block, context: context) }
    }

    private mutating func emit(_ block: DocBlock, context: Context) {
        switch block {
        case .heading(let t, let level):
            let font = SceneStyle.headingFont(level)
            let style: Style = level == 1 ? .heading1 : level == 2 ? .heading2 : .heading3
            paragraph(t, style: style, font: font, role: role(context), context: context,
                      before: previous == .start ? 0 : (level == 1 ? 18 : 14), after: 6)
            previous = .heading
        case .paragraph(let t, let style):
            if style == .quote {
                var c = context
                let f = open(.bar, context: context, margin: spacing, padding: 0)
                c.x += 14
                c.width -= 14
                paragraph(t, style: .quote, font: SceneStyle.bodyFont, role: .secondary, context: c, before: 0, after: 8)
                close(f, padding: 0, margin: 8)
            } else {
                paragraph(t, style: .body, font: SceneStyle.bodyFont, role: role(context, muted: style == .muted), context: context,
                          before: spacing, after: 6)
            }
            previous = .text
        case .item(let t, let marker, let level):
            let indent = CGFloat(level) * 20
            let markerStyled = styled(marker, SceneStyle.bodyFont, .secondary, chrome: true)
            let markerWidth = max(18, ColumnWidths.measure(markerStyled.string).line + 8)
            let before = previous == .item ? 2 : spacing
            let m = box(markerStyled, style: .marker, role: .secondary, font: SceneStyle.bodyFont, width: markerWidth,
                        dx: context.x + indent, lineSpacing: SceneStyle.proseLineSpacing, selectable: false)
            let r = role(context)
            _ = box(styled(t, SceneStyle.bodyFont, r), style: .body, role: r, font: SceneStyle.bodyFont,
                    width: context.width - indent - markerWidth, dx: context.x + indent + markerWidth,
                    lineSpacing: SceneStyle.proseLineSpacing, selectable: true)
            band(m..<(m + 2), before: before, after: 6)
            previous = .item
        case .code(let t, let lang):
            emitCode(t, json: ["json", "jsonl", "ndjson", "geojson"].contains(lang ?? ""), context: context)
            previous = .section
        case .note(let t):
            let f = open(.card(fill: .note, stroke: false, radius: 8), context: context, margin: previous == .start ? 0 : 12, padding: 10)
            var c = context
            c.x += 10
            c.width -= 20
            paragraph(t, style: .note, font: SceneStyle.noteFont, role: .secondary, context: c, before: 0, after: 0)
            close(f, padding: 10, margin: 10)
            previous = .section
        case .table(let table):
            emitTable(table, context: context)
            previous = .table
        case .fields(let rows):
            if context.inTable {
                emitFields(rows, context: context)
            } else {
                let f = open(.card(fill: .header, stroke: false, radius: 10), context: context, margin: previous == .start ? 0 : 10, padding: 12)
                var c = context
                c.x += 12
                c.width -= 24
                c.inTable = true
                emitFields(rows, context: c)
                close(f, padding: 12, margin: 14)
            }
            previous = .section
        case .section(let section):
            emitSection(section, context: context)
            previous = .section
        }
    }

    // MARK: Разделы

    private mutating func emitSection(_ section: DocSection, context: Context) {
        var c = context
        let first = previous == .start
        var frame: (index: Int, padding: CGFloat, margin: CGFloat)?
        switch section.kind {
        case .slide:
            let padding: CGFloat = options.inline ? 14 : 20
            let f = open(.card(fill: .card, stroke: true, radius: 12), context: context, margin: first ? 0 : 14, padding: padding)
            frame = (f, padding, 4)
            c.x += padding
            c.width -= padding * 2
            caption(section.title, context: c, before: 0, after: 8)
        case .sheet:
            caption(section.title, context: c, before: first ? 0 : 20, after: 8, glyph: "▦")
        case .page:
            caption(section.title, context: c, before: first ? 0 : 24, after: 8)
        case .aside, .meta:
            let f = open(.rule, context: context, margin: first ? 0 : 18, padding: 12)
            frame = (f, 0, 4)
            c.muted = true
            c.inTable = true
            caption(section.title, context: c, before: 0, after: 6)
        }
        previous = .heading
        emit(section.blocks, context: c)
        if let frame { close(frame.index, padding: frame.padding, margin: frame.margin) }
    }

    private mutating func caption(_ title: String, context: Context, before: CGFloat, after: CGFloat, glyph: String? = nil) {
        guard !title.isEmpty else { return }
        let label = (glyph.map { "\($0)  " } ?? "") + title.uppercased(with: Locale(identifier: "ru_RU"))
        let s = NSMutableAttributedString(attributedString: styled(label, SceneStyle.captionFont, .secondary, chrome: true).string)
        s.addAttribute(.kern, value: 0.4, range: NSRange(location: 0, length: s.length))
        let i = box(SceneText.Styled(string: s, marks: []), style: .caption, role: .secondary, font: SceneStyle.captionFont,
                    width: context.width, dx: context.x, lineSpacing: SceneStyle.cellLineSpacing, selectable: false)
        band(i..<(i + 1), before: before, after: after)
    }

    // MARK: Код

    private static let jsonKey = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*"(?=\s*:)"#)

    /// Код — по полосе на строку: файл в десятки тысяч строк рисуется так же быстро, как короткий.
    private mutating func emitCode(_ code: String, json: Bool, context: Context) {
        let f = open(.card(fill: .code, stroke: false, radius: 8), context: context, margin: previous == .start ? 0 : 10, padding: 12)
        let font = SceneStyle.codeFont
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            var s = styled(String(line), font, .text)
            if json {
                let m = NSMutableAttributedString(attributedString: s.string)
                for k in Self.jsonKey.matches(in: m.string, range: NSRange(location: 0, length: m.length)) {
                    m.addAttribute(SceneKey.role, value: SceneRole.secondary.rawValue, range: k.range)
                }
                s = SceneText.Styled(string: m, marks: s.marks)
            }
            let i = box(s, style: .code, role: .text, font: font, width: context.width - 24, dx: context.x + 12,
                        lineSpacing: SceneStyle.codeLineSpacing, selectable: true)
            band(i..<(i + 1), before: 0, after: SceneStyle.codeLineSpacing)
        }
        close(f, padding: 12, margin: 14)
    }

    // MARK: Поля письма

    private mutating func emitFields(_ rows: [DocField], context: Context) {
        let labelFont = SceneStyle.fieldLabelFont
        // Подпись поля — тоже содержимое: в примечаниях к ячейкам там автор («I2 · [ФИО_1]»), его надо видеть меткой
        // и уметь «Не скрывать». Копируется строкой «подпись⇥значение».
        let labels = rows.map { styled($0.label, labelFont, .secondary) }
        let natural = labels.map { ColumnWidths.measure($0.string).line }.max() ?? 60
        let labelWidth = min(max(natural, 48), context.width * 0.35) + 16
        let r = role(context)
        for (n, field) in rows.enumerated() {
            let a = box(labels[n], style: .fieldLabel, role: .secondary, font: labelFont, width: labelWidth - 12, dx: context.x, dy: 1,
                        lineSpacing: SceneStyle.cellLineSpacing, selectable: true, separator: "\t")
            _ = box(styled(field.value, SceneStyle.bodyFont, r), style: .fieldValue, role: r, font: SceneStyle.bodyFont,
                    width: context.width - labelWidth - 4, dx: context.x + labelWidth + 4, lineSpacing: SceneStyle.cellLineSpacing,
                    selectable: true)
            band(a..<(a + 2), before: n == 0 && previous != .start && previous != .heading ? 6 : 0, after: 0, padTop: 3, padBottom: 3)
        }
    }

    // MARK: Таблицы

    private static let number = try! NSRegularExpression(pattern: #"^[\s\d.,%+\-−–()€$₽]*\d[\s\d.,%+\-−–()€$₽]*$"#)

    private mutating func emitTable(_ table: DocTable, context: Context) {
        let columns = max(table.columns, 1)
        let hasLabels = table.rowLabels != nil
        let pad = SceneStyle.cellPadding
        let r = role(context)
        if let title = table.title {
            caption(title, context: context, before: previous == .start ? 0 : 12, after: 6)
            previous = .heading
        }

        // Оформление и мера каждой ячейки — параллельно: у листа на тысячу строк это тысячи ячеек. Мера — из кеша,
        // если ячейка не менялась; иначе текст набирается здесь, и тот же набор потом раскладывается по строкам.
        let rows = table.rows
        let options = self.options.text
        let matcher = self.matcher
        let cache = self.cache
        var styledRows = [[SceneText.Styled]](repeating: [], count: rows.count)
        var measures = [[ColumnWidths.Measure]](repeating: [], count: rows.count)
        var typesetters = [[CTTypesetter?]](repeating: [], count: rows.count)
        styledRows.withUnsafeMutableBufferPointer { sBuf in
            measures.withUnsafeMutableBufferPointer { mBuf in
                typesetters.withUnsafeMutableBufferPointer { tBuf in
                    nonisolated(unsafe) let s = sBuf.baseAddress!, m = mBuf.baseAddress!, t = tBuf.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: max(1, (rows.count + 31) / 32)) { chunk in
                        for i in (chunk * 32)..<min(chunk * 32 + 32, rows.count) {
                            let header = table.header && i == 0
                            let font = header ? SceneStyle.headerFont : SceneStyle.cellFont
                            let style = Self.styleKey(header ? .header : .cell, r)
                            let cells = rows[i].map { SceneText.make($0.text, font: font, role: r, options: options, matcher: matcher) }
                            var ms: [ColumnWidths.Measure] = [], ts: [CTTypesetter?] = []
                            for cell in cells {
                                let key = TextLayoutCache.Key(text: cell.string.string, marks: cell.marks, style: style, width: 0)
                                if let hit = cache.measure(key) {
                                    ms.append(hit)
                                    ts.append(nil)
                                } else {
                                    let typesetter = cell.string.length > 0 ? CTTypesetterCreateWithAttributedString(cell.string) : nil
                                    let measure = ColumnWidths.measure(cell.string, typesetter: typesetter)
                                    cache.put(key, measure)
                                    ms.append(measure)
                                    ts.append(typesetter)
                                }
                            }
                            s[i] = cells
                            m[i] = ms
                            t[i] = ts
                        }
                    }
                }
            }
        }

        // Меры столбцов: все строки, а не первые триста — иначе длинный текст в конце листа ломает сетку.
        let extra = pad.left + pad.right + 1 + 2
        var measured = [ColumnWidths.Column](repeating: ColumnWidths.Column(word: 36, line: 36, bodyLine: 0), count: columns)
        for (i, row) in rows.enumerated() {
            let header = table.header && i == 0
            var column = 0
            for (c, cell) in row.enumerated() {
                guard column < columns else { break }
                if cell.span == 1, !cell.text.isEmpty {
                    let m = measures[i][c]
                    let word = min(m.word, SceneStyle.wordLimit) + extra, line = m.line + extra
                    measured[column].word = max(measured[column].word, word)
                    measured[column].line = max(measured[column].line, line)
                    if header {
                        measured[column].headerWord = word
                    } else {
                        measured[column].bodyLine = max(measured[column].bodyLine, line)
                        measured[column].volume += m.line
                    }
                }
                column += cell.span
            }
        }
        var labelWidth: CGFloat = 0
        var labelStyled: [SceneText.Styled] = []
        if let labels = table.rowLabels {
            labelStyled = labels.map { styled($0, SceneStyle.labelFont, .tertiary, chrome: true) }
            let widest = labelStyled.map(\.string.length).max() ?? 1
            let sample = styled(String(repeating: "0", count: max(widest, 1)), SceneStyle.labelFont, .tertiary, chrome: true)
            labelWidth = ColumnWidths.measure(sample.string).line + SceneStyle.labelPadding.left + SceneStyle.labelPadding.right
        }
        let widths = ColumnWidths.fit(measured, available: context.width - labelWidth, sheet: hasLabels)
        let numeric = numericColumns(table, columns: columns)
        let tableWidth = widths.reduce(labelWidth, +)
        required = max(required, context.x + tableWidth)
        var lefts: [CGFloat] = [context.x + labelWidth]
        for w in widths { lefts.append(lefts.last! + w) }

        let tableIndex = tables.count
        tables.append(tableIndex)
        let cellAscent = SceneStyle.cellFont.ascender, labelAscent = SceneStyle.labelFont.ascender
        for (i, row) in rows.enumerated() {
            let header = table.header && i == 0
            let font = header ? SceneStyle.headerFont : SceneStyle.cellFont
            let first = boxes.count
            if hasLabels {
                _ = box(labelStyled[safe: i] ?? styled("", SceneStyle.labelFont, .tertiary, chrome: true), style: .label, role: .tertiary,
                        font: SceneStyle.labelFont, width: labelWidth - SceneStyle.labelPadding.left - SceneStyle.labelPadding.right,
                        dx: context.x + SceneStyle.labelPadding.left, dy: ceil(cellAscent - labelAscent),
                        lineSpacing: SceneStyle.cellLineSpacing, alignment: .right, selectable: false)
            }
            var edges: [CGFloat] = [context.x]
            if hasLabels { edges.append(lefts[0]) }
            var column = 0
            for (c, cell) in row.enumerated() {
                guard column < columns else { break }
                let span = min(cell.span, columns - column)
                let x = lefts[column], w = lefts[column + span] - x
                let right = span == 1 && numeric.contains(column)
                let last = column + span >= columns || c == row.count - 1
                _ = box(styledRows[i][c], style: header ? .header : .cell, role: r, font: font, width: w - pad.left - pad.right - 1,
                        dx: x + pad.left, lineSpacing: SceneStyle.cellLineSpacing, alignment: right ? .right : .left, selectable: true,
                        separator: last ? "\n" : "\t", typesetter: typesetters[i][c])
                column += span
                edges.append(lefts[column])
            }
            // Строка короче остальных: пустые ячейки до конца, чтобы сетка не обрывалась.
            while column < columns {
                column += 1
                edges.append(lefts[column])
            }
            let rowSpec = DocumentScene.Row(table: tableIndex, header: header, edges: edges, labelEdge: hasLabels ? lefts[0] : nil, first: i == 0)
            items.append(.band(PendingBand(before: i == 0 ? (previous == .start ? 0 : spacing) : 0, after: 0, padTop: pad.top,
                                           padBottom: pad.bottom, minHeight: ceil(SceneStyle.cellFont.ascender - SceneStyle.cellFont.descender),
                                           boxes: first..<boxes.count, row: rowSpec)))
        }
        if table.more > 0 {
            let text = "Ещё \(table.more) \(Plural.ru(table.more, "строка", "строки", "строк")) — в файле"
            let i = box(styled(text, SceneStyle.moreFont, .tertiary, chrome: true), style: .more, role: .tertiary, font: SceneStyle.moreFont,
                        width: context.width, dx: context.x, lineSpacing: 2, selectable: false)
            band(i..<(i + 1), before: 6, after: 4)
        }
    }

    /// Столбцы чисел (суммы, количества): почти все непустые ячейки — число. Номера, телефоны и счета
    /// здесь уже метки, так что числом остаются именно величины.
    private func numericColumns(_ table: DocTable, columns: Int) -> Set<Int> {
        var numbers = [Int](repeating: 0, count: columns), filled = [Int](repeating: 0, count: columns)
        for row in table.rows.dropFirst(table.header ? 1 : 0).prefix(500) where row.count == columns {
            for (c, cell) in row.enumerated() where !cell.text.isEmpty {
                filled[c] += 1
                let ns = cell.text as NSString
                if Self.number.firstMatch(in: cell.text, range: NSRange(location: 0, length: ns.length)) != nil { numbers[c] += 1 }
            }
        }
        return Set((0..<columns).filter { filled[$0] > 0 && Double(numbers[$0]) >= Double(filled[$0]) * 0.8 })
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
