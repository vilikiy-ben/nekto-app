import Foundation

/// Вид документа в редакторе и в ленте: блоки с формой документа, а не одна строка.
///
/// Движок отдаёт его вместе с результатом (`layout` в ответах `clean_file` и `clean_text`, схема —
/// `Engine/nekto_engine/formats/layout.py`); ответ нейросети раскладывается из Markdown здесь же (`MarkdownLayout`).
/// Тексты блоков — уже обезличенные, с метками на местах. То, что уходит в чат по «Скопировать», —
/// отдельная строка (`JobOutput.text`): человеку нужна форма документа, нейросети — текст.
struct DocumentLayout: Sendable, Equatable {
    var blocks: [DocBlock]

    static let version = 1
    /// Начало и конец значения, вернувшегося в ответ нейросети (подсвечивается зелёным). Символы из области
    /// личного использования Unicode: в тексте ответа их не бывает, на экран они не попадают (`DocumentRenderer`).
    static let restoredStart: Character = "\u{E000}"
    static let restoredEnd: Character = "\u{E001}"

    /// Старая история без вида и любой текст без формы: строка — абзац, как раньше.
    static func plain(_ text: String) -> DocumentLayout {
        DocumentLayout(blocks: text.components(separatedBy: "\n").map { .paragraph($0, style: .body) })
    }

    /// Весь видимый текст подряд: по нему считаются метки документа (панель «Скрыто», сводка «i»),
    /// поэтому в счёт идут и колонтитулы, и примечания, и свойства файла — всё, что уходит с файлом.
    var text: String {
        var out: [String] = []
        func walk(_ blocks: [DocBlock]) {
            for b in blocks {
                switch b {
                case .heading(let t, _), .paragraph(let t, _), .item(let t, _, _), .code(let t, _), .note(let t):
                    out.append(t)
                case .table(let table):
                    if let title = table.title { out.append(title) }
                    for row in table.rows { out.append(row.map(\.text).joined(separator: "\t")) }
                case .fields(let rows):
                    for f in rows { out.append(f.label + "\t" + f.value) }
                case .section(let s):
                    out.append(s.title)
                    walk(s.blocks)
                }
            }
        }
        walk(blocks)
        return out.joined(separator: "\n")
    }

    var hasTables: Bool {
        func any(_ blocks: [DocBlock]) -> Bool {
            blocks.contains { b in
                switch b {
                case .table, .fields: true
                case .section(let s): any(s.blocks)
                default: false
                }
            }
        }
        return any(blocks)
    }

    /// Начало документа для карточки в ленте: не больше `rows` строк каждой таблицы и `limit` символов.
    /// `cut` — показано не всё (карточка обрывается мягко и предлагает редактор).
    func prefix(rows: Int = 12, limit: Int = 6_000) -> (layout: DocumentLayout, cut: Bool) {
        var budget = limit
        var cut = false
        func take(_ blocks: [DocBlock]) -> [DocBlock] {
            var out: [DocBlock] = []
            for b in blocks {
                guard budget > 0 else { cut = true; break }
                switch b {
                case .table(var t):
                    if t.rows.count > rows {
                        t.more += t.rows.count - rows
                        t.rows = Array(t.rows.prefix(rows))
                        t.rowLabels = t.rowLabels.map { Array($0.prefix(rows)) }
                        cut = true
                    }
                    budget -= t.rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.text.count } }
                    out.append(.table(t))
                case .section(var s):
                    s.blocks = take(s.blocks)
                    out.append(.section(s))
                default:
                    let n = b.length
                    if n > budget, case .paragraph(let t, let style) = b {
                        out.append(.paragraph(String(t.prefix(budget)) + "…", style: style))
                        cut = true
                        budget = 0
                    } else {
                        out.append(b)
                        budget -= n
                    }
                }
            }
            return out
        }
        let blocks = take(blocks)
        return (DocumentLayout(blocks: blocks), cut)
    }

    /// Тот же вид с другим текстом в каждом блоке (ответ нейросети: метки → исходные данные).
    func mapText(_ f: (String) -> String) -> DocumentLayout {
        DocumentLayout(blocks: blocks.map { $0.mapText(f) })
    }
}

indirect enum DocBlock: Sendable, Equatable {
    enum ParagraphStyle: String, Sendable { case body, quote, muted }

    case heading(String, level: Int)
    case paragraph(String, style: ParagraphStyle)
    case item(String, marker: String, level: Int)
    case table(DocTable)
    case fields([DocField])
    case code(String, lang: String?)
    case section(DocSection)
    case note(String)

    var length: Int {
        switch self {
        case .heading(let t, _), .paragraph(let t, _), .item(let t, _, _), .code(let t, _), .note(let t): t.count
        case .table(let t): t.rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.text.count } }
        case .fields(let rows): rows.reduce(0) { $0 + $1.label.count + $1.value.count }
        case .section(let s): s.blocks.reduce(0) { $0 + $1.length }
        }
    }

    func mapText(_ f: (String) -> String) -> DocBlock {
        switch self {
        case .heading(let t, let l): return .heading(f(t), level: l)
        case .paragraph(let t, let s): return .paragraph(f(t), style: s)
        case .item(let t, let m, let l): return .item(f(t), marker: m, level: l)
        case .code(let t, let lang): return .code(f(t), lang: lang)
        case .note(let t): return .note(t)
        case .table(var t):
            t.rows = t.rows.map { $0.map { DocCell(text: f($0.text), span: $0.span) } }
            return .table(t)
        case .fields(let rows): return .fields(rows.map { DocField(label: $0.label, value: f($0.value)) })
        case .section(var s):
            s.blocks = s.blocks.map { $0.mapText(f) }
            return .section(s)
        }
    }
}

struct DocTable: Sendable, Equatable {
    var rows: [[DocCell]]
    /// Первая строка — шапка.
    var header: Bool
    var title: String?
    /// Подписи строк слева (номера строк листа Excel).
    var rowLabels: [String]?
    /// Сколько строк не показано (большая таблица; всё есть в файле).
    var more: Int = 0

    var columns: Int { rows.map { $0.reduce(0) { $0 + $1.span } }.max() ?? 0 }
}

struct DocCell: Sendable, Equatable {
    var text: String
    /// Сколько столбцов занимает (объединённые по горизонтали ячейки Word и PowerPoint).
    var span: Int = 1
}

struct DocField: Sendable, Equatable {
    var label: String
    var value: String
}

struct DocSection: Sendable, Equatable {
    enum Kind: String, Sendable {
        /// Слайд презентации — карточка.
        case slide
        /// Лист книги Excel.
        case sheet
        /// Страница.
        case page
        /// Часть файла, которую не видно на странице: колонтитулы, сноски, примечания, заметки докладчика.
        case aside
        /// Свойства файла: автор, «кем изменён».
        case meta
    }

    var kind: Kind
    var title: String
    var blocks: [DocBlock]
}

// MARK: - JSON

extension DocumentLayout {
    /// Вид из ответа движка или из `layout.json` в истории. Чужая версия или пустой вид — `nil`: покажем текст.
    init?(json: JSONValue?) {
        guard let json, (json["version"]?.int ?? 0) == Self.version else { return nil }
        let blocks = json["blocks"]?.array.compactMap(DocBlock.init(json:)) ?? []
        guard !blocks.isEmpty else { return nil }
        self.blocks = blocks
    }

    var json: JSONValue {
        .object(["version": .number(Double(Self.version)), "blocks": .array(blocks.map(\.json))])
    }
}

extension DocBlock {
    init?(json: JSONValue) {
        let text = json["text"]?.string ?? ""
        switch json["type"]?.string {
        case "heading":
            self = .heading(text, level: json["level"]?.int ?? 1)
        case "paragraph":
            self = .paragraph(text, style: ParagraphStyle(rawValue: json["style"]?.string ?? "") ?? .body)
        case "item":
            self = .item(text, marker: json["marker"]?.string ?? "•", level: json["level"]?.int ?? 0)
        case "table":
            let rows = json["rows"]?.array.map { $0.array.map(DocCell.init(json:)) } ?? []
            guard !rows.isEmpty else { return nil }
            self = .table(DocTable(rows: rows, header: json["header"]?.bool ?? false, title: json["title"]?.string,
                                   rowLabels: json["row_labels"]?.arrayOrNil?.compactMap(\.string),
                                   more: json["more"]?.int ?? 0))
        case "fields":
            let rows = json["rows"]?.array.compactMap { row -> DocField? in
                let pair = row.array.compactMap(\.string)
                return pair.count == 2 ? DocField(label: pair[0], value: pair[1]) : nil
            } ?? []
            guard !rows.isEmpty else { return nil }
            self = .fields(rows)
        case "code":
            self = .code(text, lang: json["lang"]?.string)
        case "note":
            self = .note(text)
        case "section":
            guard let kind = DocSection.Kind(rawValue: json["kind"]?.string ?? "") else { return nil }
            self = .section(DocSection(kind: kind, title: json["title"]?.string ?? "",
                                       blocks: json["blocks"]?.array.compactMap(DocBlock.init(json:)) ?? []))
        default:
            return nil
        }
    }

    var json: JSONValue {
        switch self {
        case .heading(let t, let l): ["type": "heading", "text": .string(t), "level": .number(Double(l))]
        case .paragraph(let t, let s): ["type": "paragraph", "text": .string(t), "style": .string(s.rawValue)]
        case .item(let t, let m, let l): ["type": "item", "text": .string(t), "marker": .string(m), "level": .number(Double(l))]
        case .code(let t, let lang):
            .object(["type": "code", "text": .string(t)].merging(lang.map { ["lang": .string($0)] } ?? [:]) { a, _ in a })
        case .note(let t): ["type": "note", "text": .string(t)]
        case .fields(let rows): ["type": "fields", "rows": .array(rows.map { .array([.string($0.label), .string($0.value)]) })]
        case .section(let s):
            ["type": "section", "kind": .string(s.kind.rawValue), "title": .string(s.title), "blocks": .array(s.blocks.map(\.json))]
        case .table(let t):
            // Пустые поля не пишутся: `null` в JSON — не «нет подписей строк», а значение, которое легко принять за пустой список.
            .object([
                "type": "table", "header": .bool(t.header), "more": .number(Double(t.more)),
                "rows": .array(t.rows.map { .array($0.map(\.json)) }),
            ].merging([
                "title": t.title.map(JSONValue.string),
                "row_labels": t.rowLabels.map { .array($0.map(JSONValue.string)) },
            ].compactMapValues { $0 }) { a, _ in a })
        }
    }
}

extension DocCell {
    init(json: JSONValue) {
        if let s = json.string {
            self.init(text: s)
        } else {
            self.init(text: json["text"]?.string ?? "", span: max(1, json["span"]?.int ?? 1))
        }
    }

    var json: JSONValue { span > 1 ? ["text": .string(text), "span": .number(Double(span))] : .string(text) }
}

private extension JSONValue {
    /// Массив, если это массив; `null` и всё остальное — нет значения.
    var arrayOrNil: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}
