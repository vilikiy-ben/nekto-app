#if DEBUG
import AppKit

/// Проверка редактора без рук (снимки окна): что делает человек мышью и клавишами — по аргументам запуска.
/// Срабатывает один раз, когда в редакторе появилась первая сцена.
///
/// - `-NektoCanvasScroll 0.5` — прокрутить на долю документа (шапка таблицы сверху); `mark` — к первой метке;
/// - `-NektoCanvasSelect <текст>` — выделить первое вхождение (вид выделения в ячейке);
/// - `-NektoCanvasFind <текст>` — строка поиска ⌘F с этим текстом и переходом к первому найденному
///   (строку поиска системы на время подменяет и через 5 с возвращает);
/// - `-NektoCanvasPeek YES` — как зажатая ⌥: значения на местах меток;
/// - `-NektoCanvasReport <файл>` — записать в файл выделенный текст и пункты контекстного меню на первой метке.
extension DocumentView.Coordinator {
    func runDebugScenario() {
        guard !debugScenarioDone, let canvas, canvas.scene.textLength > 0, !parent.inline else { return }
        debugScenarioDone = true
        let d = UserDefaults.standard
        if d.string(forKey: Brand.key("CanvasScroll")) == "mark",
           let box = canvas.scene.boxes.first(where: { !$0.layout.marks.isEmpty && $0.start != nil }), let m = box.layout.marks.first {
            canvas.reveal(NSRange(location: box.start! + m.range.location, length: m.range.length))
        } else if let fraction = Double(d.string(forKey: Brand.key("CanvasScroll")) ?? ""), let scroll = canvas.enclosingScrollView {
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: (canvas.frame.height - clip.bounds.height) * fraction))
            scroll.reflectScrolledClipView(clip)
        }
        if let text = d.string(forKey: Brand.key("CanvasSelect")) {
            let r = (canvas.scene.nsText).range(of: text)
            if r.location != NSNotFound {
                canvas.window?.makeFirstResponder(canvas)
                canvas.selection = r
                canvas.reveal(r)
            }
        }
        if let text = d.string(forKey: Brand.key("CanvasFind")), let finder = canvas.textFinder {
            let board = NSPasteboard(name: .find)
            let previous = board.string(forType: .string)
            board.clearContents()
            board.setString(text, forType: .string)
            canvas.window?.makeFirstResponder(canvas)
            finder.performAction(.showFindInterface)
            finder.performAction(.nextMatch)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let previous else { return }
                board.clearContents()
                board.setString(previous, forType: .string)
            }
        }
        if d.bool(forKey: Brand.key("CanvasPeek")) { setPeek(true) }
        if let path = d.string(forKey: Brand.key("CanvasReport")) {
            var lines = ["выделено: \(canvas.selectedText.replacingOccurrences(of: "\t", with: "⇥"))"]
            if let box = canvas.scene.boxes.first(where: { !$0.layout.marks.isEmpty }), let m = box.layout.marks.first, let start = box.start {
                let menu = self.menu(index: start + m.range.location, mark: nil)
                lines.append("меню на \(m.key): " + (menu?.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | ") ?? "нет"))
            }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
#endif
