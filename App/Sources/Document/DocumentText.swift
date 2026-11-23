import AppKit

/// Общее для вида документа и редактора: как выглядит метка.
/// Отдельно от интерфейса, чтобы вид документа собирался и проверялся без приложения (`scripts/checks/document-check.sh`).
enum DocumentText {
    static let tagRegex = try! NSRegularExpression(pattern: #"\[[A-ZА-ЯЁ]+_\d+\]"#)
}

/// Решения пользователя для раскраски меток в документе. От них зависит только цвет «пилюль»: раскладка документа
/// от решений не зависит, и щелчок в «Скрыто» перекрашивает метки без новой раскладки (`DocumentCanvasView`).
struct TextDecisions: Equatable, Sendable {
    /// Значение в тексте → его метка: значение стоит открытым и подсвечено «пилюлей».
    var shown: [String: String] = [:]
    /// Метка → скрывается ли значение. Нет в словаре — скрывается (метка в тексте по умолчанию синяя).
    var hidden: [String: Bool] = [:]

    func isHidden(_ placeholder: String) -> Bool { hidden[placeholder] ?? true }
}
