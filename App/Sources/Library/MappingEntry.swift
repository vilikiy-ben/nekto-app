import Foundation

/// Строка таблицы меток обработки: метка, тип, исходное значение и его написания в тексте.
struct MappingEntry: Identifiable, Hashable, Sendable {
    var id: String { placeholder }
    let placeholder: String
    let kind: String
    let original: String
    let variants: [String]
    let allowed: Bool

    init?(_ json: JSONValue) {
        guard let p = json["placeholder"]?.string, let o = json["original"]?.string else { return nil }
        placeholder = p
        original = o
        kind = json["kind"]?.string ?? ""
        variants = json["variants"]?.array.compactMap(\.string) ?? []
        allowed = json["allowed"]?.bool ?? false
    }

    var json: JSONValue {
        .object(["placeholder": .string(placeholder), "kind": .string(kind), "original": .string(original),
                 "variants": .array(variants.map(JSONValue.string)), "allowed": .bool(allowed)])
    }

    /// Все написания значения, по которым его можно найти в тексте (короче двух символов — не ищем).
    var forms: [String] { (variants + [original]).filter { $0.count >= 2 } }
}
