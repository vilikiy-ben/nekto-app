import AppKit
import SwiftUI

/// Тема оформления. Хранится в `NektoAppearance`, применяется сразу.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Авто"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    static var saved: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: Brand.key("Appearance")) ?? "") ?? .system
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func save() {
        UserDefaults.standard.set(rawValue, forKey: Brand.key("Appearance"))
        WindowCrossfade.run { apply() }
    }
}

/// Смена темы плавным переходом всего окна, как при смене оформления в Системных настройках, а не резкой
/// подменой цветов. Снимок окна кладётся поверх, под ним применяется тема, снимок растворяется.
/// Растворение — не движение, поэтому остаётся и при «Уменьшить движение», только короче.
@MainActor
enum WindowCrossfade {
    static func run(_ change: () -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let frame = window.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            change()
            return
        }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let image = NSImage(size: frame.bounds.size)
        image.addRepresentation(rep)
        let cover = NSImageView(frame: frame.bounds)
        cover.image = image
        cover.imageScaling = .scaleNone
        cover.autoresizingMask = [.width, .height]
        cover.wantsLayer = true
        frame.addSubview(cover, positioned: .above, relativeTo: nil)
        change()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cover.animator().alphaValue = 0
        } completionHandler: {
            // AppKit зовёт обработчик на главном потоке, но тип замыкания об этом не знает.
            MainActor.assumeIsolated { cover.removeFromSuperview() }
        }
    }
}

/// Настройки открываются в том же окне, что лента и редактор. Устройство как у Системных настроек
/// macOS: карточка приложения сверху, ниже сгруппированные секции, в строках цветные значки.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var appearance = Appearance.saved
    @State private var confirmErase = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.xl + Space.xs) {
                AppCard()

                SettingsSection("Оформление") {
                    HStack(spacing: Space.xl) {
                        ForEach(Appearance.allCases) { option in
                            Button {
                                guard appearance != option else { return }
                                appearance = option
                                option.save()
                            } label: {
                                EmptyView()
                            }
                            .buttonStyle(ThemeThumbStyle(option: option, selected: appearance == option))
                            .accessibilityLabel("Тема: \(option.title)")
                            .accessibilityAddTraits(appearance == option ? .isSelected : [])
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.l).padding(.vertical, Space.l)
                }

                // Одна строка: что за модель и где она лежит. Остальное (версия, Python, песочница) — для разработчика.
                SettingsSection("Модель") {
                    SettingsRow(icon: .chip, tint: Color(hex: 0x8B6CF6), title: "rubert-base-pii-ner",
                                subtitle: (AppPaths.model.path as NSString).abbreviatingWithTildeInPath) {
                        RevealButton(url: AppPaths.model)
                    }
                }

                // Отдельно от обычных настроек, ниже и со своим видом: это не настройка, а необратимое действие.
                DangerZone { confirmErase = true }
                    .padding(.top, Space.l)
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, Space.xxl)
            .padding(.top, Metrics.topBar + Space.l)
            .padding(.bottom, Space.xxl + Space.s)
            .frame(maxWidth: .infinity)
        }
        // Решение о папках с результатами принимается в момент удаления, а не заранее переключателем.
        .confirmationDialog("Стереть все данные \(Brand.name)?", isPresented: $confirmErase, titleVisibility: .visible) {
            // Кнопки отличаются одним — что с файлами в рабочих папках, и говорят это прямо.
            Button("Стереть и оставить файлы", role: .destructive) { model.eraseEverything(includingResults: false) }
            Button("Стереть вместе с файлами", role: .destructive) { model.eraseEverything(includingResults: true) }
            Button("Отмена", role: .cancel) {}
        } message: {
            // «Файлы» — то же слово, что на кнопках: видно, о чём выбор.
            Text(RU.t("Удалятся модель, история и таблицы меток. Данные в старые ответы нейросети уже не вернуть. Файлы в рабочих папках можно оставить. \(Brand.name) закроется."))
        }
    }
}

// MARK: - Карточка приложения

/// Карточка приложения сверху, как профиль в Системных настройках: на той же подложке, что и группы ниже.
/// Название и версия — одна строка (версия тише), описание — отдельной строкой, а не продолжением версии.
private struct AppCard: View {
    var body: some View {
        HStack(spacing: Space.l) {
            AppIconArt(size: 56)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(Brand.name).font(Typo.title).foregroundStyle(Ink.text)
                    Text("Версия \(version)").font(Typo.caption).monospacedDigit().foregroundStyle(Ink.text3)
                }
                Text(RU.t("Прячет персональные данные, прежде чем документ уйдёт в нейросеть."))
                    .font(Typo.callout).foregroundStyle(Ink.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.m + 2)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Ink.raised))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Ink.line, lineWidth: 0.75))
        .accessibilityElement(children: .combine)
    }

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
}

// MARK: - Строительные блоки

/// Заголовок секции, скруглённая группа строк и пояснение под ней — как в Системных настройках.
private struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(Typo.callout.weight(.semibold)).foregroundStyle(Ink.text)
                .padding(.leading, Space.xs)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Ink.raised))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Ink.line, lineWidth: 0.75))
            if let footer {
                Text(RU.t(footer)).font(Typo.caption).foregroundStyle(Ink.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xs)
            }
        }
    }
}

/// Значок строки: белый символ на цветном скруглённом квадрате.
private struct IconTile: View {
    let glyph: GlyphKind
    let tint: Color
    var body: some View {
        Glyph(kind: glyph, size: 15, weight: 1.6)
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.92), tint], startPoint: .top, endPoint: .bottom))
            )
            .accessibilityHidden(true)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let icon: GlyphKind
    let tint: Color
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(icon: GlyphKind, tint: Color, title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Space.m) {
            IconTile(glyph: icon, tint: tint)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(Typo.callout).foregroundStyle(Ink.text)
                if let subtitle {
                    // Путь можно выделить и скопировать.
                    Text(subtitle).font(Typo.small).foregroundStyle(Ink.text2).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: Space.m)
            trailing()
        }
        .padding(.horizontal, Space.m + 2).padding(.vertical, Space.s)
        .frame(minHeight: Size.settingsRow)
    }
}

/// Кнопка того же вида, что «Скопировать» и «Повторить» в ленте (`ActionButtonStyle`): капсула, подсветка
/// при наведении, затемнение при нажатии. Системная `.bordered` здесь была единственной кнопкой в приложении,
/// которая не отвечала на наведение (HIG, Pointing devices: «Use pointer effects in consistent ways throughout your app»).
private struct RevealButton: View {
    let url: URL
    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Label { Text("Показать в Finder") } icon: { Glyph(kind: .reveal, size: 15, weight: 1.5) }
        }
        .buttonStyle(ActionButtonStyle())
        .labelStyle(ActionLabelStyle())
        .disabled(!FileManager.default.fileExists(atPath: url.path))
    }
}

/// Опасная зона: внизу экрана, отдельно от настроек, красным. Что пропадёт и что это навсегда — до нажатия,
/// а не только в диалоге. Кнопка — `role: .destructive`: красный вариант общей кнопки, а не близнец
/// «Показать в Finder» (HIG, Buttons: одинаковые кнопки читаются как равноценный выбор).
private struct DangerZone: View {
    let erase: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Опасная зона").font(Typo.callout.weight(.semibold)).foregroundStyle(Ink.danger)
                .padding(.leading, Space.xs)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .center, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Стереть все данные").font(Typo.callout.weight(.medium)).foregroundStyle(Ink.text)
                    Text(RU.t("Удалит модель, историю обработок и таблицы меток. Данные в старые ответы нейросети потом не вернуть."))
                        .font(Typo.caption).foregroundStyle(Ink.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.m)
                Button(role: .destructive, action: erase) {
                    Label { Text("Стереть…") } icon: { Glyph(kind: .trash, size: 15, weight: 1.6) }
                }
                .buttonStyle(ActionButtonStyle())
                .labelStyle(ActionLabelStyle())
                .fixedSize()
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.m + 2)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Ink.danger.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Ink.danger.opacity(0.35), lineWidth: 1))
        }
    }
}

/// Миниатюра окна для выбора темы, как в разделе «Оформление» Системных настроек.
///
/// Отклик — тем же языком, что у остальных элементов приложения (строки боковой панели, «Скрыто», кнопки):
/// наведение — подложка под миниатюрой и подписью; нажатие — подложка плотнее, всё приглушается,
/// сразу; выбор — акцентное кольцо с зазором. Без подъёма и тени: так больше ничего в приложении не делает.
/// Смена самой темы — растворением окна (`WindowCrossfade`). Подпись не меняет начертание: иначе
/// центрированный текст прыгал бы по ширине.
private struct ThemeThumbStyle: ButtonStyle {
    let option: Appearance
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ThemeThumb(option: option, selected: selected, pressed: configuration.isPressed)
    }
}

private struct ThemeThumb: View {
    let option: Appearance
    let selected: Bool
    let pressed: Bool
    @State private var hover = false

    /// Скругления концентричны: окошко 8, кольцо выбора на зазоре 4 — 8 + 4 = 12, подложка на отступе 8 — 8 + 8 = 16.
    /// Кольцо с тем же радиусом, что окошко, выглядело острее его.
    private static let ringGap: CGFloat = 4
    private let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
    private let ring = RoundedRectangle(cornerRadius: Radius.control + ringGap, style: .continuous)

    var body: some View {
        VStack(spacing: Space.s) {
            preview
                .frame(width: 92, height: 60)
                .clipShape(shape)
                .overlay(shape.fill(Color.black.opacity(pressed ? 0.14 : 0)))
                .overlay(shape.strokeBorder(Ink.strongLine, lineWidth: 1))
                .overlay(
                    ring.strokeBorder(Ink.accent, lineWidth: 2.5)
                        .padding(-Self.ringGap)
                        .opacity(selected ? 1 : 0)
                )
            Text(option.title).font(Typo.caption.weight(.medium))
                .foregroundStyle(selected || hover ? Ink.text : Ink.text2)
        }
        .padding(.horizontal, Space.s).padding(.top, Space.s).padding(.bottom, Space.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: Radius.control + Space.s, style: .continuous)
                .fill(pressed ? Ink.text.opacity(0.14) : (hover ? Ink.selected : .clear))
        )
        // Как у кнопок приложения (`ActionButtonStyle`): нажатое приглушается. Затемнения самой миниатюры
        // мало — тёмное окошко на тёмной подложке от него почти не меняется.
        .opacity(pressed ? 0.75 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.08), value: pressed)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    @ViewBuilder private var preview: some View {
        switch option {
        case .light: window(dark: false)
        case .dark: window(dark: true)
        case .system:
            // Два окошка одно над другим сводятся в один слой до скругления: иначе `clipShape` сглаживает край
            // каждого слоя отдельно, и светлое окошко просвечивает в углах тёмного — светлая кайма справа.
            ZStack {
                window(dark: false)
                window(dark: true).mask(HStack(spacing: 0) { Color.clear; Color.black })
            }
            .compositingGroup()
        }
    }

    /// Окошко Nekto в миниатюре: боковая панель, заголовок, строка ввода и синий кружок отправки.
    private func window(dark: Bool) -> some View {
        let canvas = Color(hex: dark ? 0x1B1B1B : 0xFDFCFA)
        let side = Color(hex: dark ? 0x151515 : 0xF0EEEA)
        let ink = Color(hex: dark ? 0x4A4A4A : 0xD6D3CE)
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2.5) {
                    Circle().fill(Color(hex: 0xFF5F57)).frame(width: 4, height: 4)
                    Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 4, height: 4)
                    Circle().fill(Color(hex: 0x28C840)).frame(width: 4, height: 4)
                }
                .padding(.bottom, 3)
                ForEach(0..<3) { i in Capsule().fill(ink).frame(width: i == 1 ? 14 : 18, height: 2.5) }
                Spacer()
            }
            .padding(5)
            .frame(width: 30, alignment: .topLeading)
            .frame(maxHeight: .infinity)
            .background(side)
            VStack(spacing: 5) {
                Capsule().fill(ink).frame(width: 32, height: 3)
                HStack(spacing: 3) {
                    Capsule().fill(ink.opacity(0.7)).frame(height: 3)
                    Circle().fill(Color(hex: 0x3E80F7)).frame(width: 6, height: 6)
                }
                .padding(.horizontal, 4).frame(height: 10)
                .background(Capsule().fill(Color(hex: dark ? 0x2B2B2B : 0xFFFFFF)))
                .overlay(Capsule().strokeBorder(ink.opacity(0.6), lineWidth: 0.5))
                .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(canvas)
        }
    }
}

extension AppModel {
    /// Стереть всё, что Nekto оставил на этом Mac, и закрыться.
    func eraseEverything(includingResults: Bool) {
        Task {
            for job in queue { job.task?.cancel() }
            await EngineClient.shared.stop()
            let fm = FileManager.default
            for root in folders.list {
                if includingResults {
                    for p in history(root) { if let folder = p.outputFolder { try? fm.removeItem(at: folder) } }
                }
                try? fm.removeItem(at: Store.dataRoot(root))
            }
            for url in Footprint.current.everythingInLibrary { try? fm.removeItem(at: url) }
            UserDefaults.standard.removePersistentDomain(forName: Footprint.current.bundleID)
            folders.forgetAll()
            UserDefaults.standard.synchronize()
            // Сразу выходим: обычное завершение снова записало бы размер окна в настройки.
            exit(0)
        }
    }
}
