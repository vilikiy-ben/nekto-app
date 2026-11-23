import AppKit
import SwiftUI

/// Поле ввода строки «чата». NSTextView, а не TextField: большие вставки (договор целиком)
/// не тормозят, высота растёт по строкам до предела, дальше — прокрутка.
///
/// Enter — отправить, Shift+Enter или Option+Enter — новая строка. Вставка файлов (⌘V после
/// «Скопировать» в Finder) прикрепляет их, а не вставляет пути текстом.
struct ComposerField: NSViewRepresentable {
    enum Key { case up, down, enter, escape }

    @Binding var text: String
    var placeholder: String
    var focusRequest: Int
    var maxHeight: CGFloat = 220
    var onSubmit: () -> Void
    var onPasteFiles: ([URL]) -> Void
    /// Клавиши для открытого меню «+»: вернуть true, если клавиша обработана.
    var onKey: (Key) -> Bool = { _ in false }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none

        let tv = ComposerTextView()
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = .systemFont(ofSize: Typo.inputSize)
        tv.textColor = Ink.nsText
        tv.insertionPointColor = Ink.nsAccent
        tv.textContainerInset = NSSize(width: 0, height: 6)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.typingAttributes = [.font: NSFont.systemFont(ofSize: Typo.inputSize), .foregroundColor: Ink.nsText]
        tv.placeholder = placeholder
        tv.setAccessibilityLabel(placeholder)
        tv.owner = context.coordinator
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? ComposerTextView else { return }
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            tv.needsDisplay = true
        }
        if tv.placeholder != placeholder { tv.placeholder = placeholder; tv.needsDisplay = true }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let tv = nsView.documentView as? NSTextView, let lm = tv.layoutManager, let container = tv.textContainer else { return nil }
        let width = max(proposal.width ?? 400, 50)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: container)
        let content = max(lm.usedRect(for: container).height, 20) + tv.textContainerInset.height * 2
        return CGSize(width: width, height: min(ceil(content), maxHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        var focusRequest = -1

        init(parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            tv.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if parent.onKey(.enter) { return true }
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.moveUp(_:)):
                return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onKey(.down)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onKey(.escape)
            default:
                return false
            }
        }

        func pasteFiles(_ urls: [URL]) { parent.onPasteFiles(urls) }
    }
}

final class ComposerTextView: NSTextView {
    var placeholder = ""
    weak var owner: ComposerField.Coordinator?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: Typo.inputSize), .foregroundColor: NSColor.placeholderTextColor]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            owner?.pasteFiles(urls)
            return
        }
        pasteAsPlainText(sender)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // Текст из буфера иногда приходит испорченным (UTF-8, прочитанный как MacRoman) — чиним.
        if let s = pboard.string(forType: .string) {
            insertText(TextRepair.fix(s), replacementRange: selectedRange())
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }
}
