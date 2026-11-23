import AppKit

/// Подтверждение удаления обработки: системное окно-лист с флажком «удалить и файлы».
///
/// `NSAlert`, а не `confirmationDialog`: флажок у системного предупреждения уже есть (`suppressionButton`,
/// по умолчанию «Больше не спрашивать»), ему достаточно другой подписи. Так диалог ведёт себя как системный:
/// Return удаляет, Esc отменяет, флажок переключается пробелом и читается VoiceOver.
@MainActor
enum DeleteConfirmation {
    /// Выбор флажка запоминается: кто однажды оставил файлы, обычно оставляет их и дальше.
    private static let keepFilesKey = "DeleteKeepsResultFiles"

    /// `window` — окно, к которому лист крепится (окно `ShellView`, `HostWindow`); без него — отдельное модальное окно.
    static func present(for p: Processing, in window: NSWindow?, onDelete: @escaping (_ includingFiles: Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Удалить «\(p.title)»?"
        alert.informativeText = RU.t("Вернуть данные в ответы нейросети по этой обработке больше не получится.")

        let delete = alert.addButton(withTitle: "Удалить")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Отмена").keyEquivalent = "\u{1b}"

        // Флажок — только если файлы есть: иначе он спрашивал бы о том, чего нет.
        let hasFiles = p.outputFolder.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if hasFiles {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Удалить и файлы, созданные в этой обработке"
            alert.suppressionButton?.state = UserDefaults.standard.bool(forKey: keepFilesKey) ? .off : .on
        }

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let includingFiles = hasFiles && alert.suppressionButton?.state == .on
            if hasFiles { UserDefaults.standard.set(!includingFiles, forKey: keepFilesKey) }
            onDelete(includingFiles)
        }
        // Показ — на следующем витке цикла, не из обновления SwiftUI, откуда приходит просьба (`ShellView.onChange`).
        // Кнопки алерта на macOS 26 сами нарисованы SwiftUI, а вложенное обновление посреди чужого откладывается:
        // `beginSheetModal` держит главный поток всю анимацию листа, и красная «Удалить» проступала только в её конце,
        // через ~200 мс после «Отмены». Видно на покадровой записи экрана.
        DispatchQueue.main.async {
            if let window {
                alert.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(alert.runModal())
            }
        }
    }
}
