import AppKit

/// Оформление вида документа: шрифты, отступы, сетка. Числа — те же, что были у прежнего вида на NSTextView,
/// чтобы документ выглядел знакомо; меняется только то, как он раскладывается и рисуется.
///
/// Цвета здесь не хранятся: в тексте лежит только роль (`Role`), а цвет берётся при рисовании в текущей теме
/// (`ScenePalette`). Поэтому раскладку можно строить в фоне, а смена темы и решений в «Скрыто» не требует
/// раскладывать документ заново.
enum SceneStyle {
    // MARK: Шрифты
    // NSFont неизменяем и потокобезопасен (это CTFont): раскладка в фоне читает те же объекты.

    nonisolated(unsafe) static let bodyFont = NSFont.systemFont(ofSize: Typo.bodySize)
    nonisolated(unsafe) static let cellFont = NSFont.systemFont(ofSize: 13)
    nonisolated(unsafe) static let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    nonisolated(unsafe) static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    nonisolated(unsafe) static let captionFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    nonisolated(unsafe) static let codeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    nonisolated(unsafe) static let noteFont = NSFont.systemFont(ofSize: 12.5)
    nonisolated(unsafe) static let fieldLabelFont = NSFont.systemFont(ofSize: 13)
    nonisolated(unsafe) static let moreFont = NSFont.systemFont(ofSize: 12)

    static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: .systemFont(ofSize: 20, weight: .semibold)
        case 2: .systemFont(ofSize: 17, weight: .semibold)
        default: .systemFont(ofSize: 15, weight: .semibold)
        }
    }

    /// Метка `[ФИО_1]` — моноширинная, на полтора пункта мельче текста вокруг.
    static func tagFont(around size: CGFloat) -> NSFont { Typo.nsMono(size - 1.5, .semibold) }
    /// Исходное значение на месте метки при ⌥ — шрифтом текста, чуть крупнее: видно, что это подсмотренное.
    static func peekFont(around size: CGFloat) -> NSFont { .systemFont(ofSize: size + 1.5, weight: .medium) }

    // MARK: Метрики

    /// Межстрочный интервал прозы и ячеек.
    static let proseLineSpacing: CGFloat = 5
    static let cellLineSpacing: CGFloat = 2
    static let codeLineSpacing: CGFloat = 2
    /// Отступы текста в ячейке.
    static let cellPadding = NSEdgeInsets(top: 5, left: 9, bottom: 6, right: 9)
    /// Столбец номеров строк листа: отступ слева и справа от номера.
    static let labelPadding: (left: CGFloat, right: CGFloat) = (6, 8)
    /// «Пилюля» метки выходит за текст на столько с каждой стороны.
    static let pillOutset: CGFloat = 3
    static let pillRadius: CGFloat = 5
    /// Место под «пилюлю» с каждой стороны метки: сама пилюля и точка зазора до соседней буквы или запятой.
    static let pillGap: CGFloat = pillOutset + 1
    /// Самое длинное слово, ради которого столбец расширяется (дальше слово переносится).
    static let wordLimit: CGFloat = 220
    /// У листа — то же, но строже: лист читают строками, и редкое длинное слово не должно уводить его вбок.
    /// Метка (`[ПАСПОРТ_12]` ≈ 95 pt) помещается всегда.
    static let sheetWordLimit: CGFloat = 150
    /// Столбец листа, который читают глазами, — не уже этого (если в нём есть что читать).
    static let comfortableColumn: CGFloat = 120
    /// Толщина линии сетки (в точках; на Retina — один пиксель).
    static let hairline: CGFloat = 0.5

    /// Отступы редактора от краёв окна (в ленте — без отступов).
    static let readerInset = NSSize(width: 40, height: 28)
    static let inlineInset = NSSize(width: 0, height: 2)
}

/// Что за текст: от этого зависит цвет при рисовании.
enum SceneRole: Int, Sendable {
    case text, secondary, tertiary
}

/// Свои атрибуты текста вида. Роль — `SceneRole.rawValue`; метки и значения — отдельно, в `SceneMark`.
enum SceneKey {
    static let role = NSAttributedString.Key(Brand.key("Role"))
}

/// Цвета на время одной отрисовки: динамические цвета приложения, разрешённые в текущей теме окна.
struct ScenePalette {
    let text, secondary, tertiary: CGColor
    let accent, accentSoft, mutedSoft, restoredSoft: CGColor
    let grid, line, headerFill, labelFill, cardFill, codeFill, noteFill, canvas: CGColor
    let selection, selectionInactive: CGColor

    /// Вызывать внутри `NSAppearance.performAsCurrentDrawingAppearance`.
    static func current() -> ScenePalette {
        ScenePalette(
            text: Ink.nsText.cgColor, secondary: Ink.nsText2.cgColor, tertiary: Ink.nsText3.cgColor,
            accent: Ink.nsAccent.cgColor, accentSoft: Ink.nsAccentSoft.cgColor, mutedSoft: Ink.nsMutedSoft.cgColor,
            restoredSoft: Ink.nsRestoredSoft.cgColor,
            grid: Ink.nsGrid.cgColor, line: Ink.nsLine.cgColor, headerFill: Ink.nsHeaderFill.cgColor,
            labelFill: Ink.nsLabelFill.cgColor, cardFill: Ink.nsCardFill.cgColor, codeFill: Ink.nsCodeFill.cgColor,
            noteFill: Ink.nsNoteFill.cgColor, canvas: Ink.nsCanvas.cgColor,
            selection: NSColor.selectedTextBackgroundColor.cgColor,
            selectionInactive: NSColor.unemphasizedSelectedTextBackgroundColor.cgColor)
    }

    /// Весь текст одним цветом и без «пилюль» — для текста на жёлтой плашке найденного.
    static func ink(_ color: CGColor) -> ScenePalette {
        let clear = CGColor(gray: 0, alpha: 0)
        return ScenePalette(
            text: color, secondary: color, tertiary: color, accent: color,
            accentSoft: clear, mutedSoft: clear, restoredSoft: clear,
            grid: clear, line: clear, headerFill: clear, labelFill: clear, cardFill: clear, codeFill: clear,
            noteFill: clear, canvas: clear, selection: clear, selectionInactive: clear)
    }

    func color(for role: SceneRole) -> CGColor {
        switch role {
        case .text: text
        case .secondary: secondary
        case .tertiary: tertiary
        }
    }
}
