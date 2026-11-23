import AppKit
import SwiftUI

/// Иконка приложения внутри интерфейса: онбординг, карточка в настройках, «О программе».
///
/// Не `NSApp.applicationIconImage`: та следует теме системы (как Dock), а окно — теме приложения
/// (Настройки → Оформление). При «Светлой» теме в тёмной системе карточка показывала бы чёрную плитку
/// на белом. `AppIconArt` в `Brand.xcassets` — рендеры того же `AppIcon.icon` через ictool, светлый и тёмный;
/// вариант выбирается по теме вида, поэтому меняется вместе с окном, без перерисовки вручную.
/// Картинки — рендеры `AppIcon.icon` (Icon Composer) в светлой и тёмной теме; при смене иконки их нужно пересобрать.
///
/// Рамка — как у системной иконки: плитка занимает 824/1024 холста, вокруг прозрачные поля под тень.
struct AppIconArt: View {
    var size: CGFloat

    var body: some View {
        Image(.appIconArt)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Стандартное окно «О программе» с той же иконкой: панель живёт в теме приложения,
/// а без явной иконки AppKit подставил бы системную (по теме системы).
@MainActor
enum AboutPanel {
    static func show() {
        let credits = NSAttributedString(
            string: RU.t("Прячет персональные данные, прежде чем документ уйдёт в нейросеть."),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centered,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationIcon: NSImage(resource: .appIconArt),
            .credits: credits,
        ])
        NSApp.activate()
    }

    private static var centered: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }
}
