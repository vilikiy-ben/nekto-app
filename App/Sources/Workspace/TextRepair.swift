import Foundation

/// Чинит текст, который по дороге испортили: UTF-8, прочитанный как MacRoman («–ü—Ä–∏–≤–µ—Ç»)
/// или Windows-1252 («ÐŸÑ€Ð¸Ð²ÐµÑ‚»). Так ведут себя некоторые мосты буфера обмена и старые программы.
/// Исправляем только если признаки явные и результат — валидный UTF-8 с кириллицей.
enum TextRepair {
    static func fix(_ text: String) -> String {
        guard text.count >= 6 else { return text }
        for (markers, encoding) in [("–—", String.Encoding.macOSRoman), ("ÐÑ", .windowsCP1252), ("ÐÑ", .isoLatin1)] {
            let hits = text.unicodeScalars.filter { markers.unicodeScalars.contains($0) }.count
            guard hits >= 3, Double(hits) / Double(text.count) > 0.08 else { continue }
            if let data = text.data(using: encoding, allowLossyConversion: false),
               let fixed = String(data: data, encoding: .utf8),
               fixed.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil {
                return fixed
            }
        }
        return text
    }
}
