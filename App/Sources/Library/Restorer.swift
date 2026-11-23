import Foundation

/// Возврат исходных данных в ответ нейросети.
enum Restorer {
    struct Result: Sendable {
        var text: String
        var restored: [NSRange]
        var unknown: [String]
    }

    nonisolated(unsafe) private static let bracketed = try! Regex(#"\[([A-ZА-ЯЁ]+)_(\d+)\]"#)

    static func restore(_ input: String, mapping: [MappingEntry]) -> Result {
        guard !mapping.isEmpty, !input.isEmpty else { return Result(text: input, restored: [], unknown: []) }
        let table = Dictionary(mapping.map { ($0.placeholder, $0.original) }, uniquingKeysWith: { a, _ in a })
        // Нейросети иногда теряют скобки: «ФИО_1» → тоже метка, если такая есть в обработке.
        let bare = Dictionary(mapping.map { (String($0.placeholder.dropFirst().dropLast()), $0.original) }, uniquingKeysWith: { a, _ in a })
        var out = ""
        var ranges: [NSRange] = []
        var unknown: [String] = []
        var cursor = input.startIndex
        let pattern = try! Regex(#"\[?([A-ZА-ЯЁ]+_\d+)\]?"#)
        for match in input.matches(of: pattern) {
            let token = String(input[match.range])
            let key = String(match.output[1].substring ?? "")
            let replacement: String?
            if token.hasPrefix("[") && token.hasSuffix("]") {
                replacement = table[token]
            } else {
                let before = match.range.lowerBound == input.startIndex ? " " : input[input.index(before: match.range.lowerBound)]
                let after = match.range.upperBound == input.endIndex ? " " : input[match.range.upperBound]
                let isolated = !(before.isLetter || before.isNumber) && !(after.isLetter || after.isNumber)
                replacement = isolated ? bare[key] : nil
            }
            out += input[cursor..<match.range.lowerBound]
            if let replacement {
                ranges.append(NSRange(location: out.utf16.count, length: replacement.utf16.count))
                out += replacement
            } else {
                if token.hasPrefix("["), token.hasSuffix("]") { unknown.append(token) }
                out += token
            }
            cursor = match.range.upperBound
        }
        out += input[cursor...]
        return Result(text: out, restored: ranges, unknown: unknown)
    }

    static func tagCounts(in text: String) -> [(tag: String, count: Int)] {
        var counts: [String: Set<String>] = [:]
        for m in text.matches(of: bracketed) {
            let kind = String(m.output[1].substring ?? "")
            counts[kind, default: []].insert(String(text[m.range]))
        }
        return counts.map { ($0.key, $0.value.count) }.sorted { $0.count == $1.count ? $0.tag < $1.tag : $0.count > $1.count }
    }
}
