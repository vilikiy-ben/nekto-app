import Foundation

/// Русская типографика для строк интерфейса: короткие слова не остаются в конце строки,
/// число не отрывается от единицы, многоточие и кавычки — правильные символы.
enum RU {
    private static let nbsp = "\u{00A0}"
    private static let short: Set<String> = [
        "а", "в", "и", "к", "о", "с", "у", "я", "во", "до", "за", "из", "на", "не", "ни", "но", "об", "от", "по",
        "со", "то", "уже", "без", "для", "или", "над", "под", "при", "про", "что", "это", "все", "его", "её", "их",
    ]

    static func t(_ text: String) -> String {
        let words = text.components(separatedBy: " ")
        guard words.count > 1 else { return text }
        var out = ""
        for (i, w) in words.enumerated() {
            out += w
            guard i < words.count - 1 else { break }
            let bare = w.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            let next = words[i + 1]
            let glue = short.contains(bare) && !w.hasSuffix(",") && !w.hasSuffix(".")   // предлог к следующему слову
                || w.allSatisfy(\.isNumber) && !w.isEmpty                               // «2 ГБ», «465 МБ»
                || i == words.count - 2 && next.count <= 8                              // последнее слово не одно
            out += glue ? nbsp : " "
        }
        return out
    }

    private static let ru = Locale(identifier: "ru_RU")

    /// «1 166 МБ» с неразрывными пробелами.
    static func megabytes(_ bytes: Int64) -> String {
        let mb = Int((Double(bytes) / 1_000_000).rounded())
        return mb.formatted(.number.locale(ru)) + nbsp + "МБ"
    }

    /// «23 %».
    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(ru))
    }
}

/// Русские формы множественного числа: 1 замена, 2 замены, 5 замен.
enum Plural {
    static func ru(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }
}

/// Человеческие названия типов меток для сводок: «ФИО 8 · телефоны 4 · почта 4».
enum KindNames {
    static let names: [String: String] = [
        "ФИО": "ФИО", "АДРЕС": "адреса", "ДАТА": "даты", "ДР": "даты рождения", "ТЕЛЕФОН": "телефоны", "EMAIL": "почта",
        "ПАСПОРТ": "паспорта", "СНИЛС": "СНИЛС", "ИНН": "ИНН", "СЧЁТ": "счета", "КАРТА": "карты",
        "IP": "IP-адреса", "MAC": "MAC-адреса", "ССЫЛКА": "ссылки", "НИК": "ники", "НОМЕР": "номера",
        "СЕКРЕТ": "пароли и ключи", "ОРГ": "организации", "ПДН": "прочее",
    ]

    static func name(_ tag: String) -> String { names[tag] ?? tag.lowercased() }

    /// Заголовок группы в панели «Скрыто»: с заглавной буквы.
    static func title(_ tag: String) -> String {
        let n = name(tag)
        return n == n.uppercased() ? n : n.prefix(1).uppercased() + n.dropFirst()
    }
}
