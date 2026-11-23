import AppKit

/// Метка или значение внутри куска текста: где стоит и что это. Цвет «пилюли» решается при рисовании
/// по текущим решениям (`TextDecisions`), поэтому щелчок в «Скрыто» не требует раскладывать текст заново.
struct SceneMark: Sendable, Hashable {
    enum Kind: UInt8, Sendable {
        /// Метка `[ФИО_1]`; `key` — сама метка.
        case tag
        /// Значение, стоящее в тексте открытым; `key` — его прежняя метка.
        case shown
        /// Исходное значение на месте метки, пока зажата ⌥; `key` — метка.
        case peek
        /// Значение, вернувшееся в ответ нейросети.
        case restored
    }

    var range: NSRange
    var kind: Kind
    var key: String
}

/// Как размечать текст документа: обезличенный документ (метки) или ответ нейросети (вернувшиеся значения).
struct SceneTextOptions: Sendable, Equatable {
    var replies = false
    /// Зажата ⌥: на местах меток — исходные значения.
    var peek = false
    var originals: [String: String] = [:]
    /// Значения, стоящие в тексте открытыми (значение → метка).
    var shown: [String: String] = [:]
}

/// Текст куска документа с оформлением: шрифт, роль и метки. Строится без интерфейса (в фоне).
enum SceneText {
    struct Styled: @unchecked Sendable {
        let string: NSAttributedString
        let marks: [SceneMark]
    }

    /// Цвет букв — из контекста рисования (`TextLayout.drawRuns` ставит его по роли); без этого CoreText рисует чёрным.
    static let colorFromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)

    /// `chrome` — служебный текст вида (подписи, номера строк): метки в нём не ищутся.
    static func make(_ raw: String, font: NSFont, role: SceneRole, chrome: Bool = false,
                     options: SceneTextOptions, matcher: ShownMatcher?) -> Styled {
        var text = raw
        var marks: [SceneMark] = []
        if options.replies {
            (text, marks) = stripRestored(raw)
        } else if !chrome {
            (text, marks) = findTags(raw, options: options, matcher: matcher)
        }
        let out = NSMutableAttributedString(string: text, attributes: [.font: font, SceneKey.role: role.rawValue, Self.colorFromContext: true])
        guard !marks.isEmpty else { return Styled(string: out, marks: []) }
        let kern = SceneStyle.pillGap
        let ns = text as NSString
        for m in marks where m.range.length > 0 {
            switch m.kind {
            case .tag, .shown: out.addAttribute(.font, value: SceneStyle.tagFont(around: font.pointSize), range: m.range)
            case .peek: out.addAttribute(.font, value: SceneStyle.peekFont(around: font.pointSize), range: m.range)
            case .restored: break
            }
            // Место под «пилюлю»: она выходит за текст, соседние буквы не должны под неё заходить.
            out.addAttribute(.kern, value: kern, range: NSRange(location: NSMaxRange(m.range) - 1, length: 1))
            if m.range.location > 0 {
                let before = ns.character(at: m.range.location - 1)
                if before != 0x0A, before != 0x2028 {
                    out.addAttribute(.kern, value: kern, range: NSRange(location: m.range.location - 1, length: 1))
                }
            }
        }
        return Styled(string: out, marks: marks)
    }

    /// Метки и открытые значения; при ⌥ метки заменяются исходными значениями.
    private static func findTags(_ raw: String, options: SceneTextOptions, matcher: ShownMatcher?) -> (String, [SceneMark]) {
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        let tags = DocumentText.tagRegex.matches(in: raw, range: full).map(\.range)
        var marks: [SceneMark] = []
        if let matcher {
            for m in matcher.regex.matches(in: raw, range: full)
            where !tags.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                guard let placeholder = matcher.placeholder(for: ns.substring(with: m.range)) else { continue }
                marks.append(SceneMark(range: m.range, kind: .shown, key: placeholder))
            }
        }
        for r in tags { marks.append(SceneMark(range: r, kind: .tag, key: ns.substring(with: r))) }
        marks.sort { $0.range.location < $1.range.location }
        guard options.peek, !tags.isEmpty else { return (raw, marks) }
        // ⌥: строка собирается заново, метки — исходными значениями, места остальных отметок сдвигаются.
        var out = ""
        var cursor = 0
        var shifted: [SceneMark] = []
        let utf16Count = { (s: String) in (s as NSString).length }
        var outLength = 0
        for m in marks {
            let gap = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += gap
            outLength += utf16Count(gap)
            var piece = ns.substring(with: m.range)
            var kind = m.kind
            if m.kind == .tag, let original = options.originals[m.key], !original.isEmpty {
                piece = original
                kind = .peek
            }
            shifted.append(SceneMark(range: NSRange(location: outLength, length: utf16Count(piece)), kind: kind, key: m.key))
            out += piece
            outLength += utf16Count(piece)
            cursor = NSMaxRange(m.range)
        }
        out += ns.substring(from: cursor)
        return (out, shifted)
    }

    /// Ответ нейросети: значения, вернувшиеся на место меток, отмечены символами-скобками (`MarkdownLayout.reply`).
    static func stripRestored(_ raw: String) -> (String, [SceneMark]) {
        let start = DocumentLayout.restoredStart.unicodeScalars.first!, end = DocumentLayout.restoredEnd.unicodeScalars.first!
        guard raw.unicodeScalars.contains(start) else { return (raw, []) }
        var out = String.UnicodeScalarView()
        var marks: [SceneMark] = []
        var openAt: Int?
        var length = 0
        for scalar in raw.unicodeScalars {
            if scalar == start {
                openAt = length
            } else if scalar == end {
                if let a = openAt, length > a { marks.append(SceneMark(range: NSRange(location: a, length: length - a), kind: .restored, key: "")) }
                openAt = nil
            } else {
                out.append(scalar)
                length += scalar.utf16.count
            }
        }
        return (String(out), marks)
    }
}

/// Открытые значения в тексте: регулярка «любое из них» и метка по найденному написанию.
struct ShownMatcher: @unchecked Sendable {
    let regex: NSRegularExpression
    private let lookup: [String: String]

    init?(_ shown: [String: String]) {
        guard let regex = Self.anyOf(shown.keys) else { return nil }
        self.regex = regex
        lookup = Dictionary(shown.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    func placeholder(for match: String) -> String? { lookup[match.lowercased()] }

    /// Одна регулярка на все значения: длинные раньше коротких, без учёта регистра. Один проход по тексту
    /// вместо прохода на каждое значение.
    static func anyOf(_ values: some Collection<String>) -> NSRegularExpression? {
        let parts = values.filter { $0.count >= 2 }.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        guard !parts.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: parts.joined(separator: "|"), options: [.caseInsensitive])
    }
}
