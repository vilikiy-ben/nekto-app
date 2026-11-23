import Foundation

/// Markdown → вид документа. Нужен для ответа нейросети: модели отвечают Markdown-разметкой (таблицы, списки,
/// заголовки), и показывать её звёздочками и палками — та же стена текста, что была у таблиц.
///
/// Разбирает Foundation (`AttributedString(markdown:)`, полный синтаксис, включая таблицы GitHub): блоки
/// приходят как `presentationIntent` каждого куска текста. Метки `[ФИО_1]` разбор не трогает — ссылок без адреса
/// в Markdown не бывает. Выделение внутри строки (жирный, курсив) не переносится: в редакторе важна форма, а не начертание.
enum MarkdownLayout {
    static func parse(_ markdown: String) -> DocumentLayout {
        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
        else { return .plain(markdown) }
        var builder = Builder()
        for run in attributed.runs {
            builder.add(String(attributed[run.range].characters), intent: run.presentationIntent)
        }
        let layout = builder.finish()
        return layout.blocks.isEmpty ? .plain(markdown) : layout
    }

    /// Ответ нейросети: разметка ответа и исходные данные на месте меток, отмеченные для зелёной подсветки.
    static func reply(_ markdown: String, mapping: [MappingEntry]) -> DocumentLayout {
        parse(markdown).mapText { text in
            let restored = Restorer.restore(text, mapping: mapping)
            guard !restored.restored.isEmpty else { return restored.text }
            let ns = restored.text as NSString
            var out = ""
            var cursor = 0
            for r in restored.restored {
                out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                out += "\(DocumentLayout.restoredStart)\(ns.substring(with: r))\(DocumentLayout.restoredEnd)"
                cursor = NSMaxRange(r)
            }
            return out + ns.substring(from: cursor)
        }
    }

    /// Куски текста одного блока Markdown складываются вместе; новый блок начинается, когда меняется
    /// самый внутренний элемент разметки (абзац, ячейка, пункт).
    private struct Builder {
        var blocks: [DocBlock] = []
        private var text = ""
        private var current: (id: Int, make: (String) -> DocBlock?)?
        private var table: (id: Int, rows: [[DocCell]], rowIDs: [Int], header: Bool)?

        mutating func add(_ chunk: String, intent: PresentationIntent?) {
            let parts = intent?.components ?? []
            guard let inner = parts.first else {
                append(chunk, id: -1) { .paragraph($0, style: .body) }
                return
            }
            if let tableIntent = parts.first(where: { if case .table = $0.kind { true } else { false } }) {
                addCell(chunk, parts: parts, table: tableIntent.identity)
                return
            }
            let lists = parts.filter { if case .orderedList = $0.kind { true } else if case .unorderedList = $0.kind { true } else { false } }
            let quoted = parts.contains { if case .blockQuote = $0.kind { true } else { false } }
            switch inner.kind {
            case .header(let level):
                append(chunk, id: inner.identity) { .heading($0, level: min(level, 3)) }
            case .codeBlock(let lang):
                append(chunk, id: inner.identity) { .code($0.hasSuffix("\n") ? String($0.dropLast()) : $0, lang: lang) }
            case .thematicBreak:
                flush()
            default:
                if let list = lists.first, let item = parts.first(where: { if case .listItem = $0.kind { true } else { false } }),
                   case .listItem(let ordinal) = item.kind {
                    let ordered: Bool = if case .orderedList = list.kind { true } else { false }
                    let level = lists.count - 1
                    append(chunk, id: inner.identity) { .item($0, marker: ordered ? "\(ordinal)." : "•", level: level) }
                } else {
                    append(chunk, id: inner.identity) { .paragraph($0, style: quoted ? .quote : .body) }
                }
            }
        }

        private mutating func append(_ chunk: String, id: Int, make: @escaping (String) -> DocBlock?) {
            flushTable()
            if current?.id != id { flush(); current = (id, make) }
            text += chunk
        }

        private mutating func addCell(_ chunk: String, parts: [PresentationIntent.IntentType], table id: Int) {
            flush()
            if table?.id != id { flushTable(); table = (id, [], [], false) }
            guard var t = table else { return }
            var column = 0
            var rowID = -1
            for p in parts {
                switch p.kind {
                case .tableCell(let c): column = c
                case .tableHeaderRow: rowID = p.identity; t.header = true
                case .tableRow: rowID = p.identity
                default: break
                }
            }
            if t.rowIDs.last != rowID { t.rowIDs.append(rowID); t.rows.append([]) }
            while t.rows[t.rows.count - 1].count <= column { t.rows[t.rows.count - 1].append(DocCell(text: "")) }
            t.rows[t.rows.count - 1][column].text += chunk
            table = t
        }

        private mutating func flush() {
            if let current, !text.isEmpty, let block = current.make(text) { blocks.append(block) }
            current = nil
            text = ""
        }

        private mutating func flushTable() {
            guard let t = table else { return }
            table = nil
            blocks.append(.table(DocTable(rows: t.rows, header: t.header && t.rows.count > 1)))
        }

        mutating func finish() -> DocumentLayout {
            flush()
            flushTable()
            return DocumentLayout(blocks: blocks)
        }
    }
}
