import AppKit
import SwiftUI


/// Палитра Nekto: графит и тёплая бумага, один акцент — «синька» из иконки приложения.
///
/// Цвета динамические: каждый токен знает свой вид в светлой и тёмной теме и при включённом
/// «Повысить контраст» (Универсальный доступ → Дисплей), поэтому экраны не ветвятся по `colorScheme`.
/// Синий акцент — единственный «громкий» цвет: им отмечено то, что скрыто, и главное действие.
/// Зелёный — данные, вернувшиеся в ответ нейросети, и подтверждение («Скопировано»).
///
/// Текст в три ступени, как `label` / `secondaryLabel` / `tertiaryLabel` у системы:
/// `text` — содержимое, `text2` — всё, что нужно прочитать (подписи, пояснения), `text3` — то,
/// без чего можно обойтись (счётчики, расширения файлов, заглушки). `text3` не ниже 3,5 : 1.
enum Ink {
    // Поверхности
    static let canvas = tone(light: 0xFDFCFA, dark: 0x1B1B1B)
    static let sidebar = tone(light: 0xF4F3F0, dark: 0x151515)
    static let raised = tone(light: 0xFFFFFF, dark: 0x2B2B2B)       // строка ввода, карточки
    static let bubble = tone(light: 0xF0EEEA, dark: 0x2C2C2C)       // сообщение пользователя

    // Линии и состояния
    static let line = overlay(light: 0.09, dark: 0.09, contrast: 0.22)
    static let strongLine = overlay(light: 0.14, dark: 0.13, contrast: 0.35)
    static let hover = overlay(light: 0.045, dark: 0.055)
    static let selected = overlay(light: 0.075, dark: 0.09)
    /// Значок-кнопка внутри строки, которая уже подсвечена наведением: наведение и нажатие (или открытое меню)
    /// должны читаться поверх подсветки строки, поэтому плотнее `hover` и `selected`.
    static let controlHover = overlay(light: 0.09, dark: 0.11)
    static let controlPressed = overlay(light: 0.14, dark: 0.17)

    // Текст
    static let text = tone(light: 0x1D1C1A, dark: 0xECECEC)
    static let text2 = tone(light: 0x6B6862, dark: 0xA0A0A0, contrast: (0x4A4741, 0xC4C4C4))
    static let text3 = tone(light: 0x85817A, dark: 0x808080, contrast: (0x5E5A54, 0xA8A8A8))

    // Смысловые
    static let accent = tone(light: 0x1F63EC, dark: 0x4C8DFF, contrast: (0x0B4BC4, 0x7AABFF))
    static let accentSoft = tone(light: 0x1F63EC, dark: 0x4C8DFF, alpha: (0.11, 0.20))
    static let restored = tone(light: 0x14894A, dark: 0x3DD27E, contrast: (0x0B6B37, 0x5BE496))
    static let danger = tone(light: 0xD93A3F, dark: 0xFF6B6B, contrast: (0xB0262B, 0xFF8A8A))

    // Для NSTextView
    static let nsText = nsTone(light: 0x1D1C1A, dark: 0xE6E6E6)
    static let nsText2 = nsTone(light: 0x6B6862, dark: 0xA0A0A0, contrast: (0x4A4741, 0xC4C4C4))
    static let nsAccent = nsTone(light: 0x1F63EC, dark: 0x6FA3FF, contrast: (0x0B4BC4, 0x8DB8FF))
    static let nsAccentSoft = nsTone(light: 0x1F63EC, dark: 0x4C8DFF, alpha: (0.11, 0.22))
    static let nsMutedSoft = nsTone(light: 0x000000, dark: 0xFFFFFF, alpha: (0.07, 0.10))
    static let nsDanger = nsTone(light: 0xD93A3F, dark: 0xFF6B6B, contrast: (0xB0262B, 0xFF8A8A))
    static let nsRestoredSoft = nsTone(light: 0x1E9E58, dark: 0x3DD27E, alpha: (0.18, 0.24))
    static let nsText3 = nsTone(light: 0x85817A, dark: 0x808080, contrast: (0x5E5A54, 0xA8A8A8))

    // Форма документа в редакторе (`DocumentRenderer`): сетка таблиц, шапка, карточки слайдов, код
    static let nsGrid = nsTone(light: 0x000000, dark: 0xFFFFFF, alpha: (0.13, 0.14), contrast: (0x000000, 0xFFFFFF))
    static let nsLine = nsTone(light: 0x000000, dark: 0xFFFFFF, alpha: (0.10, 0.11))
    static let nsHeaderFill = nsTone(light: 0x000000, dark: 0xFFFFFF, alpha: (0.045, 0.06))
    static let nsLabelFill = nsTone(light: 0x000000, dark: 0xFFFFFF, alpha: (0.025, 0.03))
    static let nsCardFill = nsTone(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: (1, 0.035))
    static let nsCodeFill = nsTone(light: 0x000000, dark: 0xFFFFFF, alpha: (0.04, 0.05))
    static let nsCanvas = nsTone(light: 0xFDFCFA, dark: 0x1B1B1B)
    static let nsRaised = nsTone(light: 0xFFFFFF, dark: 0x2B2B2B)
    static let nsNoteFill = nsTone(light: 0x1F63EC, dark: 0x4C8DFF, alpha: (0.06, 0.10))

    // MARK: Построение

    /// `contrast` — вариант для «Повысить контраст» (светлый, тёмный).
    static func nsTone(light: UInt32, dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1),
                       contrast: (UInt32, UInt32)? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let pair = appearance.isHighContrast ? (contrast ?? (light, dark)) : (light, dark)
            return appearance.isDark ? NSColor(hex: pair.1, alpha: alpha.1) : NSColor(hex: pair.0, alpha: alpha.0)
        }
    }

    static func tone(light: UInt32, dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1),
                     contrast: (UInt32, UInt32)? = nil) -> Color {
        Color(nsColor: nsTone(light: light, dark: dark, alpha: alpha, contrast: contrast))
    }

    /// Полупрозрачный слой: чёрный на светлом, белый на тёмном. С повышенным контрастом — плотнее.
    static func overlay(light: CGFloat, dark: CGFloat, contrast: CGFloat? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let boost = a.isHighContrast ? contrast : nil
            return a.isDark ? NSColor(white: 1, alpha: boost ?? dark) : NSColor(white: 0, alpha: boost ?? light)
        })
    }
}

extension NSAppearance {
    var isDark: Bool {
        guard let m = bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) else { return false }
        return m == .darkAqua || m == .accessibilityHighContrastDarkAqua
    }
    var isHighContrast: Bool {
        let m = bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        return m == .accessibilityHighContrastAqua || m == .accessibilityHighContrastDarkAqua
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) { self.init(nsColor: NSColor(hex: hex, alpha: alpha)) }
}

/// Шкала шрифтов: семь ступеней вместо россыпи размеров через полпункта.
///
/// Основа — системный SF Pro. Чтение (лента, документ, строки списков) — 14 pt: приложение
/// читают подолгу, а не пробегают глазами, как меню. Подписи и элементы управления — 13 pt, как у
/// macOS. Вес выделяет главное в пределах ступени, а не новый размер.
enum Typo {
    static let display = Font.system(size: 28)                          // вопрос главного экрана, онбординг
    static let title = Font.system(size: 20, weight: .semibold)        // карточка приложения
    static let body = Font.system(size: 14)                            // лента, списки, документ
    static let callout = Font.system(size: 13)                         // подписи, кнопки, строки настроек
    static let caption = Font.system(size: 12)                         // пояснения, счётчики, подвалы
    static let small = Font.system(size: 11)                           // подзаголовки строк, клавиши

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func nsMono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
    /// Размер основного текста документа.
    static let bodySize: CGFloat = 14
    static let inputSize: CGFloat = 15
}

/// Отступы на сетке 4 pt: 8 — между элементами, 16 — внутри блоков, 24 — между группами, 32 — между крупными блоками.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Скругления. Вложенные фигуры концентричны: внутренний радиус = внешний − отступ.
enum Radius {
    static let small: CGFloat = 6       // флажок, клавиша, метка в тексте
    static let control: CGFloat = 8     // значки-кнопки, плитки настроек
    static let row: CGFloat = 10        // строки списков и меню
    static let tile: CGFloat = 12       // плитки файлов, кольцо выбора темы
    static let card: CGFloat = 16       // карточки результата, группы настроек (не меньше капсулы кнопки внутри)
    static let bubble: CGFloat = 18     // сообщение пользователя
    static let field: CGFloat = 26      // строка ввода и карточка файлов
}

/// Высоты элементов: 28 — компактные кнопки, 32 — строки списков, 36 — кнопки строки ввода, 44 — строки настроек.
enum Size {
    static let compact: CGFloat = 28
    static let row: CGFloat = 32
    static let control: CGFloat = 36
    static let settingsRow: CGFloat = 44
}

/// Метрики, общие для всех экранов.
enum Metrics {
    static let topBar: CGFloat = 52           // высота полосы со «светофором»
    static let column: CGFloat = 760          // ширина колонки ленты и строки ввода
    static let sidebarDefault: CGFloat = 260
    static let inspectorDefault: CGFloat = 300
}
