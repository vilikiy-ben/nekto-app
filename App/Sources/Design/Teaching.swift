import Foundation
import SwiftUI
import TipKit

/// Объяснения, которые нужны один раз. Подсказка при наведении не помнит, что её уже прочли,
/// и показывается каждый раз; TipKit помнит: подсказка уходит навсегда после закрытия или после того,
/// как человек сделал то, чему она учит.
///
/// Здесь только неочевидные жесты: перетащить файл в чат, подсмотреть исходные данные (⌥),
/// скрыть пропущенное (правый щелчок). Что делает кнопка с подписью, здесь не объясняется.
enum Teaching {
    /// Вызывается один раз при запуске, до первого `TipView`.
    @MainActor
    static func configure() {
        #if DEBUG
        let d = UserDefaults.standard
        // `-NektoResetTips YES` — показать подсказки снова, как в первый запуск.
        if d.bool(forKey: Brand.key("ResetTips")) { try? Tips.resetDatastore() }
        // `-NektoTipsImmediate YES` — без паузы между подсказками, для проверки.
        let frequency: Tips.ConfigurationOption.DisplayFrequency = d.bool(forKey: Brand.key("TipsImmediate")) ? .immediate : .daily
        #else
        let frequency: Tips.ConfigurationOption.DisplayFrequency = .daily
        #endif
        // Не больше одной новой подсказки в день: HIG, «set the display frequency so tips display at a reasonable cadence».
        try? Tips.configure([.displayFrequency(frequency), .datastoreLocation(.applicationDefault)])
    }

    /// Человек сделал то, чему учит подсказка: больше её не показываем.
    static func learned(_ tip: some Tip) {
        tip.invalidate(reason: .actionPerformed)
    }
}

/// Результат — это файл, и его можно унести в чат мышью. Без подсказки это не видно ничем, кроме курсора-руки.
struct DragToChatTip: Tip {
    var title: Text { Text("Файл можно унести в чат") }
    var message: Text? { Text(RU.t("Возьмите карточку за шапку и отпустите в окне нейросети.")) }
}

/// Исходные данные под метками — по желанию, а не при случайном наведении.
struct PeekTip: Tip {
    var title: Text { Text("Что под метками?") }
    var message: Text? { Text(RU.t("Удерживайте ⌥ — метки на время покажут исходные данные.")) }
}

/// Модель находит не всё. Как скрыть пропущенное — в панели «Скрыто», пока человек этим занят.
struct HideMissedTip: Tip {
    var title: Text { Text("Модель что-то пропустила?") }
    var message: Text? { Text(RU.t("Выделите это в тексте и выберите «Скрыть» в меню по правому щелчку.")) }
    /// Показывается, когда человек проверяет документ, — даже если сегодня уже была другая подсказка.
    var options: [any TipOption] { [Tips.IgnoresDisplayFrequency(true)] }
}
