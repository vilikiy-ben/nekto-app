import AppKit
import CoreText

/// Ширина столбцов таблицы.
///
/// У столбца есть минимум (слово целиком: метку рвать нельзя) и потолок (самая длинная строка без переносов).
/// Помещается всё одной строкой — столбцы по потолку. Нет — каждому минимум, а остаток делится по объёму
/// текста в столбце: столбец с длинными отзывами забирает больше, столбец с датой остаётся по дате.
///
/// Лист (XLSX, CSV) прежде раскладывался «как в Excel»: столбец не шире 280 pt, остальное — прокрутка вбок,
/// и на листе с длинными отзывами главный столбец уезжал за край окна. Теперь вбок лист прокручивается,
/// только когда не помещаются и минимумы (много столбцов или узкое окно).
enum ColumnWidths {
    struct Measure: Sendable {
        var word: CGFloat
        var line: CGFloat
    }

    /// Самое длинное слово и самая длинная строка куска текста — тем же шрифтом, что на экране (с метками).
    /// Одна строка CoreText на весь кусок: ширины слов и строк — разности позиций букв в ней. `typesetter` —
    /// уже готовый набор букв того же текста (его же потом возьмёт раскладка: текст набирается один раз).
    static func measure(_ s: NSAttributedString, typesetter: CTTypesetter? = nil) -> Measure {
        let ns = s.string as NSString
        let length = ns.length
        guard length > 0 else { return Measure(word: 0, line: 0) }
        let ct = typesetter.map { CTTypesetterCreateLine($0, CFRange(location: 0, length: length)) } ?? CTLineCreateWithAttributedString(s)
        // Конец текста — полная ширина строки: позиция «после последней буквы» у CoreText не включает отступ после неё
        // (место под «пилюлю» метки), а набор строки включает — без этого ячейка, которая кончается меткой, рвала её.
        let full = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
        func x(_ i: Int) -> CGFloat { i >= length ? full : CTLineGetOffsetForStringIndex(ct, i, nil) }
        var word: CGFloat = 0, line: CGFloat = 0
        var lineStart = 0, wordStart = -1, lastVisible = 0
        for i in 0...length {
            let c: unichar = i < length ? ns.character(at: i) : 0x0A
            if isBreak(c) || isSpace(c) {
                if wordStart >= 0 {
                    word = max(word, x(i) - x(wordStart))
                    lastVisible = i
                    wordStart = -1
                }
                if isBreak(c) {
                    if lastVisible > lineStart { line = max(line, x(lastVisible) - x(lineStart)) }
                    lineStart = i + 1
                    lastVisible = lineStart
                }
            } else {
                if wordStart < 0 { wordStart = i }
                // После «/» и дефиса строка тоже переносится: «Отдел/Группа», «сине-зелёный», ссылки — не одно слово.
                if breaksAfter(c), i + 1 < length, !isSpace(ns.character(at: i + 1)) {
                    word = max(word, x(i + 1) - x(wordStart))
                    wordStart = -1
                    lastVisible = i + 1
                }
            }
        }
        return Measure(word: ceil(word), line: ceil(line))
    }

    private static func isBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029 }
    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0xA0 }
    private static func breaksAfter(_ c: unichar) -> Bool { c == 0x2F || c == 0x2D || c == 0x2010 || c == 0x2013 || c == 0x2014 || c == 0x5C }

    /// Меры столбца по всем строкам (уже с отступами ячейки).
    struct Column: Sendable {
        /// Самое длинное слово (не больше `SceneStyle.wordLimit`) и самая длинная строка без переносов.
        var word: CGFloat = 0
        var line: CGFloat = 0
        /// То же без шапки: шапка «Итоговая оценка» не должна делать широким столбец оценок «8».
        var bodyLine: CGFloat = 0
        var headerWord: CGFloat = 0
        /// Сколько текста в столбце всего (сумма строк): кому отдавать свободное место.
        var volume: CGFloat = 0
    }

    /// Ширины столбцов в `available` точек. `sheet` — лист Excel/CSV.
    static func fit(_ columns: [Column], available: CGFloat, sheet: Bool) -> [CGFloat] {
        let high = columns.map { max($0.word, $0.line) }
        let maxTotal = high.reduce(0, +)
        if maxTotal <= available { return high }
        // Нижняя граница — самое длинное слово целиком (метка — тоже слово). У листа ещё и удобная ширина для
        // столбцов с текстом: столбец отзывов не сжимается до одного слова в строке. Слово длиннее `sheetWordLimit`
        // (ссылка с параметрами, номер счёта без пробелов) у листа переносится, а не раздвигает лист вбок.
        let floor: [CGFloat] = sheet
            ? zip(columns, high).map { c, h in
                min(h, max(c.headerWord, min(c.word, SceneStyle.sheetWordLimit), min(c.bodyLine, SceneStyle.comfortableColumn)))
            }
            : zip(columns, high).map { c, h in min(h, c.word) }
        let minTotal = floor.reduce(0, +)
        // Не помещаются и минимумы: таблица шире места. В редакторе она прокручивается вбок, в ленте обрезается краем
        // с затуханием — сжимать дальше нельзя, порвутся слова и метки. Документ остаётся по минимумам. Лист, раз уж
        // его всё равно листают вбок, получает четверть сверх минимумов — её забирают столбцы с длинным текстом,
        // иначе отзыв в узкой панели вытягивался в столбик в слово шириной.
        var target = available
        if minTotal >= available {
            guard sheet else { return floor.map { $0.rounded(.up) } }
            target = min(minTotal * 1.25, maxTotal)
        }
        // Остаток — по объёму текста, но не шире самой длинной строки: столбец отзывов получает больше,
        // чем столбец с названием магазина, и таблица выходит ниже. Кто упёрся в потолок — отдаёт излишек остальным.
        var out = floor
        var room = target - minTotal
        for _ in 0..<columns.count where room > 0.5 {
            let open = out.indices.filter { out[$0] < high[$0] - 0.5 }
            guard !open.isEmpty else { break }
            let weights = open.map { max(columns[$0].volume, high[$0] - out[$0], 1) }
            let total = weights.reduce(0, +)
            var used: CGFloat = 0
            for (k, i) in open.enumerated() {
                let add = min(room * weights[k] / total, high[i] - out[i])
                out[i] += add
                used += add
            }
            room -= used
        }
        out = out.map { $0.rounded(.down) }
        // Округление вниз оставляет пару точек — отдаём их самому широкому столбцу, чтобы край таблицы был ровным.
        if let widest = out.indices.max(by: { out[$0] < out[$1] }) { out[widest] += max(0, target - out.reduce(0, +)) }
        return out
    }
}
