import Foundation
import Observation

/// Черновик в строке ввода: либо текст, либо файлы, и режимы будущей обработки.
@MainActor
@Observable
final class Composer {
    var text = ""
    /// Прикреплённые файлы. Пока они есть, поле текста скрыто: отправляются только файлы,
    /// а набранный текст ждёт своей очереди и вернётся, когда файлы уйдут.
    private(set) var attachments: [URL] = []
    /// Режимы для новой обработки. В открытой обработке режимы живут в самой обработке.
    var modes: Set<ProcessingMode> = []
    /// Счётчик-сигнал: строка ввода забирает фокус клавиатуры, когда он меняется.
    var focusRequest = 0

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasFiles: Bool { !attachments.isEmpty }
    var canSend: Bool { hasFiles || !trimmedText.isEmpty }

    func attach(_ urls: [URL]) {
        for url in urls where !attachments.contains(url) { attachments.append(url) }
    }

    func detach(_ url: URL) { attachments.removeAll { $0 == url } }

    func clearAttachments() { attachments = [] }

    func insert(_ pasted: String) {
        if text.isEmpty || text.hasSuffix("\n") || text.hasSuffix(" ") { text += pasted } else { text += "\n" + pasted }
    }

    /// Чистая строка для новой обработки с режимами по умолчанию (последний выбор, `ReviewPreferences`).
    func reset(modes: Set<ProcessingMode>) {
        text = ""
        attachments = []
        self.modes = modes
    }
}
