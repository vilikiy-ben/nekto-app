import AppKit

// Проверки вида документа и движка редактора (`App/Sources/Document`, `DocumentCanvasView`): `scripts/checks/document-check.sh`.
// Код возврата 1 — есть нарушения.
// `--png <папка>` — заодно сохранить картинки раскладки (светлая и тёмная тема) для глаз.

var failures = 0
var passed = 0

@MainActor func check(_ ok: Bool, _ what: String) {
    if ok { passed += 1 } else { failures += 1; print("✗ \(what)") }
}

func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

let pngDir: URL? = CommandLine.arguments.firstIndex(of: "--png").map { URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) }

MainActor.assumeIsolated {
    // MARK: JSON из движка и обратно
    let engine = json("""
    {"version": 1, "blocks": [
      {"type": "heading", "text": "Договор [НОМЕР_1]", "level": 1},
      {"type": "item", "text": "Купить билеты", "marker": "1.", "level": 0},
      {"type": "table", "rows": [["ФИО", "Телефон"], ["[ФИО_1]", {"text": "[ТЕЛЕФОН_1]", "span": 2}]], "header": true},
      {"type": "section", "kind": "slide", "title": "Слайд 1", "blocks": [{"type": "paragraph", "text": "[ФИО_2]"}]},
      {"type": "section", "kind": "meta", "title": "Свойства файла", "blocks": [{"type": "fields", "rows": [["Автор", "[ФИО_3]"]]}], "copy": false},
      {"type": "unknown"}
    ]}
    """)
    let layout = DocumentLayout(json: engine)
    check(layout?.blocks.count == 5, "вид из движка: неизвестный блок пропущен, остальные на месте")
    if case .table(let t)? = layout?.blocks[2] {
        check(t.header && t.rowLabels == nil && t.rows[1][1].span == 2 && t.columns == 3, "таблица: шапка, объединённая ячейка, без номеров строк")
    } else { check(false, "таблица из движка") }
    let again = DocumentLayout(json: try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(layout!.json)))
    check(again == layout, "вид переживает layout.json без изменений")
    check(DocumentLayout(json: json(#"{"version": 2, "blocks": [{"type": "note", "text": "x"}]}"#)) == nil, "чужая версия вида — текстом")
    let nullLabels = json(#"{"version": 1, "blocks": [{"type": "table", "rows": [["a"]], "header": false, "row_labels": null, "title": null}]}"#)
    if case .table(let t)? = DocumentLayout(json: nullLabels)?.blocks.first {
        check(t.rowLabels == nil, "row_labels: null — нет номеров строк, а не пустой столбец")
    } else { check(false, "таблица с null") }
    check(layout!.text.contains("[ФИО_3]"), "текст вида (для «Скрыто») включает свойства файла")

    // MARK: Начало документа для ленты
    let rows = (0..<40).map { [DocCell(text: "[ФИО_\($0)]"), DocCell(text: "x")] }
    let big = DocumentLayout(blocks: [.table(DocTable(rows: rows, header: true, rowLabels: (1...40).map(String.init)))])
    let head = big.prefix(rows: 12)
    if case .table(let t) = head.layout.blocks[0] {
        check(head.cut && t.rows.count == 12 && t.more == 28 && t.rowLabels?.count == 12, "лента: 12 строк таблицы, остальное — «ещё 28 строк»")
    } else { check(false, "лента: таблица") }

    // MARK: Markdown и ответ нейросети
    let md = MarkdownLayout.parse("# План\n\nСвязаться с [ФИО_1].\n\n- раз\n  - вложенный\n\n| Кто | Тел |\n|---|---|\n| [ФИО_1] | [ТЕЛЕФОН_1] |\n\n```\nкод\n```")
    let kinds = md.blocks.map { b -> String in
        switch b { case .heading: "h"; case .paragraph: "p"; case .item(_, _, let l): "i\(l)"; case .table: "t"; case .code: "c"; default: "?" }
    }
    check(kinds == ["h", "p", "i0", "i1", "t", "c"], "Markdown → блоки: \(kinds)")
    check(md.text.contains("[ФИО_1]"), "Markdown не трогает метки")
    let mapping = [MappingEntry(json(#"{"placeholder": "[ФИО_1]", "original": "Иванов Иван", "kind": "ФИО"}"#))!]
    let reply = MarkdownLayout.reply("| Кто |\n|---|\n| [ФИО_1] |\n\nПозвонить [ФИО_1] и [ФИО_7]", mapping: mapping)
    let replyScene = SceneBuilder(options: .init(width: 700, text: .init(replies: true))).build(reply)
    check(!replyScene.text.contains("\u{E000}") && !replyScene.text.contains("\u{E001}"), "метки возврата не видны на экране")
    var restored: [String] = []
    for box in replyScene.boxes {
        for m in box.layout.marks where m.kind == .restored { restored.append((box.layout.string.string as NSString).substring(with: m.range)) }
    }
    check(restored == ["Иванов Иван", "Иванов Иван"] && replyScene.text.contains("[ФИО_7]"),
          "ответ: два возврата подсвечены ровно по значению, чужая метка осталась — \(restored)")

    // MARK: Раскладка
    /// Строка раскладки, в которой стоит буква.
    func line(_ layout: TextLayout, _ index: Int) -> Int {
        layout.lines.firstIndex { NSLocationInRange(index, $0.range) } ?? -1
    }
    /// Порвана ли метка или слово (начало и конец — в разных строках).
    func broken(_ scene: DocumentScene, words: [String]) -> [String] {
        var out: [String] = []
        for box in scene.boxes {
            let ns = box.layout.string.string as NSString
            for m in box.layout.marks where line(box.layout, m.range.location) != line(box.layout, NSMaxRange(m.range) - 1) {
                out.append(ns.substring(with: m.range))
            }
            for w in words {
                let r = ns.range(of: w)
                if r.location != NSNotFound, line(box.layout, r.location) != line(box.layout, NSMaxRange(r) - 1) { out.append(w) }
            }
        }
        return out
    }
    // Сама проверка видит разрыв: слово в узкой колонке обязано разорваться.
    do {
        let narrow = TextLayout(SceneText.make("Инфраструктура", font: SceneStyle.cellFont, role: .text, options: .init(), matcher: nil),
                                width: 40, lineSpacing: 2, font: SceneStyle.cellFont)
        check(line(narrow, 0) != line(narrow, 13), "контроль: разрыв слова заметен")
    }
    let sheet = DocumentLayout(blocks: [.section(DocSection(kind: .sheet, title: "Сотрудники", blocks: [.table(DocTable(
        rows: [["Таб. №", "ФИО", "Должность", "Отдел", "Моб. телефон", "E-mail", "Дата рождения", "Оклад", "Комментарий"].map { DocCell(text: $0) }]
            + (1...6).map { i in ["[НОМЕР_\(i)]", "[ФИО_\(i)]", "Руководитель проекта", "Инфраструктура", "[ТЕЛЕФОН_\(i)]", "[EMAIL_\(i)]",
                                  "[ДР_\(i)]", "245000", "паспорт [ПАСПОРТ_\(i)], проживает: [АДРЕС_\(i)]"].map { DocCell(text: $0) } },
        header: true, rowLabels: (1...7).map(String.init)))]))])
    for width: CGFloat in [420, 700, 1400] {
        for inline in [false, true] {
            let scene = SceneBuilder(options: .init(width: width, inline: inline)).build(sheet)
            let bad = broken(scene, words: ["Инфраструктура", "Должность", "Комментарий"])
            check(bad.isEmpty, "ширина \(Int(width))\(inline ? " (лента)" : ""): слова и метки не рвутся — \(bad.prefix(3))")
            if width == 420 { check(scene.size.width > width, "узкое окно: лист шире окна, редактор прокручивается вбок") }
            if width == 1400 { check(scene.size.width == width, "широкое окно: лист в окне, без прокрутки вбок") }
        }
    }
    let wide = DocumentLayout(blocks: [.paragraph(String(repeating: "Вступление к таблице. ", count: 40), style: .body)] + sheet.blocks)
    let wideScene = SceneBuilder(options: .init(width: 500)).build(wide)
    check(wideScene.size.width > 500 && wideScene.boxes[0].layout.usedWidth <= 500, "абзацы вокруг широкой таблицы — по ширине окна")

    // MARK: Лист с длинными отзывами: 1300 строк, в каждой — от одной до пятнадцати фраз
    var seed: UInt64 = 7
    func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
    let phrases = ["Инструкцию по сборке переписали понятнее", "но в пятницу очередь в пункте выдачи", "Видео по настройке удобное",
                   "спасибо курьерам, [ФИО_12] и [ФИО_40] привезли в выходной", "возвраты оформляют долго", "каталог давно не обновляли",
                   "Кухня/Посуда/Сковороды", "без замечаний"]
    let feedback = DocumentLayout(blocks: [.section(DocSection(kind: .sheet, title: "Лист1", blocks: [.table(DocTable(
        rows: [["Магазин", "Отзыв", "Товар", "Доставка", "Упаковка", "Итоговая оценка"].map { DocCell(text: $0) }]
            + (0..<1300).map { _ in
                ["Москва / Пункт выдачи на Тверской / Вечерняя смена",
                 (0..<(1 + rnd(14))).map { _ in phrases[rnd(phrases.count)] }.joined(separator: ". ") + ".",
                 "Дом / Текстиль / Пледы", "\(1 + rnd(10))", "\(1 + rnd(10))", "\(1 + rnd(10))"].map { DocCell(text: $0) }
            },
        header: true, rowLabels: (1...1301).map(String.init)))]))])
    let feedbackCache = TextLayoutCache()
    var t0 = Date()
    let feedbackScene = SceneBuilder(options: .init(width: 900), cache: feedbackCache).build(feedback)
    let coldMs = Date().timeIntervalSince(t0) * 1000
    check(broken(feedbackScene, words: []).isEmpty, "отзывы: метки не рвутся")
    check(feedbackScene.size.width == 900, "отзывы в окне 900 pt: без прокрутки вбок (\(Int(feedbackScene.size.width)))")

    // Полнота: всё, что касается любой полосы, рисуется. У прежнего вида (TextKit 1) на таком листе 21 % полос теряли строки.
    var monotonic = true
    for (a, b) in zip(feedbackScene.bands, feedbackScene.bands.dropFirst()) where a.bottom > b.top + 0.01 { monotonic = false }
    check(monotonic, "полосы идут сверху вниз и не перекрываются")
    var lost = 0, strips = 0
    for y in stride(from: 0, to: feedbackScene.size.height, by: 97) {
        let strip = CGRect(x: 0, y: y, width: feedbackScene.size.width, height: 256)
        let drawn = Set(feedbackScene.bands(in: strip.insetBy(dx: 0, dy: -ScenePainter.overhang)).flatMap { Array(feedbackScene.bands[$0].boxes) })
        strips += 1
        for (i, box) in feedbackScene.boxes.enumerated() where box.frame.intersects(strip) && !drawn.contains(i) { lost += 1 }
        for (i, box) in feedbackScene.boxes.enumerated() where box.frame.maxY > strip.minY && box.frame.minY < strip.maxY {
            for l in box.layout.lines where box.origin.y + l.top < strip.maxY && box.origin.y + l.top + l.height > strip.minY && !drawn.contains(i) { lost += 1 }
        }
    }
    check(lost == 0, "полнота: \(strips) полос по 256 pt, потеряно кусков текста: \(lost)")

    // Мышь и текст: середина метки → место внутри метки; прямоугольники куска → тот же кусок.
    var hits = 0, misses = 0
    for (i, box) in feedbackScene.boxes.enumerated().prefix(3000) {
        guard let start = box.start else { continue }
        for m in box.layout.marks {
            let range = NSRange(location: start + m.range.location, length: m.range.length)
            guard let r = feedbackScene.rects(for: range).first else { misses += 1; continue }
            let index = feedbackScene.index(at: CGPoint(x: r.midX, y: r.midY))
            if NSLocationInRange(index, range) { hits += 1 } else { misses += 1 }
            if feedbackScene.mark(at: CGPoint(x: r.midX, y: r.midY))?.key != m.key { misses += 1 }
            _ = i
        }
    }
    check(hits > 50 && misses == 0, "мышь попадает в метки: \(hits) попаданий, \(misses) промахов")

    // Копирование строки таблицы — ячейки через табуляцию: вставляется в Excel таблицей.
    if let rowBand = feedbackScene.bands.first(where: { $0.row != nil && !$0.row!.header }) {
        let starts = rowBand.boxes.compactMap { feedbackScene.boxes[$0].start }, ends = rowBand.boxes.compactMap { feedbackScene.boxes[$0].end }
        let row = (feedbackScene.text as NSString).substring(with: NSRange(location: starts.min()!, length: ends.max()! - starts.min()!))
        check(row.components(separatedBy: "\t").count == 6 && !row.contains("\n"), "строка таблицы копируется через табуляцию")
    }

    // Правка в «Скрыто»: тот же документ с одним изменённым значением раскладывается заново только в этой ячейке.
    let edited = feedback.mapText { $0.replacingOccurrences(of: "[ФИО_12]", with: "Иванов Иван") }
    let madeBefore = feedbackCache.made
    t0 = Date()
    let editedScene = SceneBuilder(options: .init(width: 900), cache: feedbackCache).build(edited)
    let editMs = Date().timeIntervalSince(t0) * 1000
    let changed = Set(feedbackScene.boxes.map(\.layout.string.string).filter { $0.contains("[ФИО_12]") }).count
    check(editedScene.boxes.count == feedbackScene.boxes.count && feedbackCache.made - madeBefore == changed,
          "правка: заново разложены только изменённые ячейки (\(feedbackCache.made - madeBefore), изменено \(changed) разных)")

    // ⌥: метки — исходными значениями, отметка остаётся (пилюля на месте).
    let peekScene = SceneBuilder(options: .init(width: 900, text: .init(peek: true, originals: ["[ФИО_12]": "Петров Пётр"]))).build(feedback)
    let peekMarks = peekScene.boxes.flatMap { b in b.layout.marks.filter { $0.kind == .peek }.map { (b.layout.string.string as NSString).substring(with: $0.range) } }
    check(!peekMarks.isEmpty && Set(peekMarks) == ["Петров Пётр"] && !peekScene.text.contains("[ФИО_12]") && peekScene.text.contains("[ФИО_40]"),
          "⌥: метка с известным значением показана значением, остальные — метками")
    // Открытые значения отмечены своей меткой.
    let shownScene = SceneBuilder(options: .init(width: 900, text: .init(shown: ["Иванов Иван": "[ФИО_12]"]))).build(edited)
    check(shownScene.boxes.contains { $0.layout.marks.contains { $0.kind == .shown && $0.key == "[ФИО_12]" } }, "открытое значение отмечено своей меткой")

    // MARK: Время
    let heavy = DocumentLayout(blocks: [.table(DocTable(
        rows: (0..<1666).map { i in (0..<12).map { c in DocCell(text: c == 1 ? "[ФИО_\(i)]" : c == 9 ? "Командировка в ПАО «ПРИМЕРТЕХ» 19–23 мая" : "Ячейка \(i)") } },
        header: true, rowLabels: (1...1666).map(String.init)))])
    t0 = Date()
    _ = SceneBuilder(options: .init(width: 900)).build(heavy)
    let heavyMs = Date().timeIntervalSince(t0) * 1000

    // Кадр: холст рисует экран 900 × 800 в разных местах документа.
    let canvas = DocumentCanvasView(frame: NSRect(x: 0, y: 0, width: 980, height: 800))
    canvas.setScene(feedbackScene)
    canvas.updateSize()
    let screen = NSRect(x: 0, y: 0, width: 980, height: 800)
    let rep = canvas.bitmapImageRepForCachingDisplay(in: screen)!
    var frames: [Double] = []
    for i in 0..<60 {
        let y = CGFloat(i) * (feedbackScene.size.height - 800) / 60
        let t = Date()
        canvas.cacheDisplay(in: screen.offsetBy(dx: 0, dy: y), to: rep)
        frames.append(Date().timeIntervalSince(t) * 1000)
    }
    frames.sort()
    print(String(format: "отзывы 1300 строк: сборка %.0f мс, после правки %.0f мс; 20 тыс. ячеек: %.0f мс; экран 980×800: медиана %.1f мс, p95 %.1f мс, худший %.1f мс",
                 coldMs, editMs, heavyMs, frames[30], frames[56], frames.last!))
    check(coldMs < 1000 && heavyMs < 1000, "сборка большого листа — меньше секунды")
    check(editMs < coldMs, "после правки — быстрее первой сборки")
    check(frames[56] < 8, "целый экран рисуется быстрее полукадра (p95 < 8 мс)")

    if let pngDir {
        try? FileManager.default.createDirectory(at: pngDir, withIntermediateDirectories: true)
        let short = DocumentLayout(blocks: [.section(DocSection(kind: .sheet, title: "Лист1", blocks: [.table(DocTable(
            rows: Array(feedback.blocks.first.flatMap { if case .section(let s) = $0, case .table(let t) = s.blocks[0] { t.rows } else { nil } }!.prefix(8)),
            header: true, rowLabels: (1...8).map(String.init)))]))])
        for (name, doc, width) in [("sheet", sheet, CGFloat(900)), ("feedback", short, 900), ("reply", reply, 700), ("engine", layout!, 700)] {
            for dark in [false, true] {
                let scene = SceneBuilder(options: .init(width: width, text: .init(replies: name == "reply"))).build(doc)
                let view = DocumentCanvasView(frame: .zero)
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                view.appearance = appearance
                view.setScene(scene)
                view.frame = NSRect(x: 0, y: 0, width: scene.size.width + 80, height: scene.size.height + 56)
                // Холст рисуется прямо в битмап с фоном редактора: в PNG — то, что на экране.
                let size = view.bounds.size
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                let ctx = NSGraphicsContext(bitmapImageRep: rep)!
                NSGraphicsContext.current = ctx
                appearance.performAsCurrentDrawingAppearance {
                    Ink.nsCanvas.setFill()
                    NSRect(origin: .zero, size: size).fill()
                    ctx.cgContext.translateBy(x: 0, y: size.height)
                    ctx.cgContext.scaleBy(x: 1, y: -1)
                    view.draw(view.bounds)
                }
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: pngDir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

print("Вид документа: \(passed) проверок прошли, \(failures) не прошли")
exit(failures == 0 ? 0 : 1)
