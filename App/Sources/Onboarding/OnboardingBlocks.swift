import AppKit
import SwiftUI

/// Блоки правой колонки онбординга: образец, три шага, что скачается и ход установки, выбор папки, чёрточки шагов.
/// Размеры — из макета онбординга (блоки `specimen`, `steps`, `install`, `folders`, `dashes`).

enum OnboardingText {
    /// Межстрочный текста 14 pt в колонке: 21 pt, как в макете (у системы 17).
    static let leading: CGFloat = Space.xs
}

/// Карточка онбординга: приподнятая поверхность, тонкая рамка, скругление карточек.
private struct OnboardingCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Ink.raised))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Ink.line))
    }
}

private extension View {
    func onboardingCard() -> some View { modifier(OnboardingCard()) }
}

private struct Hairline: View {
    var body: some View { Rectangle().fill(Ink.line).frame(height: 1) }
}

// MARK: 1 · Образец

/// Строка документа до и после: что Nekto меняет. Метки — как в тексте приложения, синие плашки.
struct SpecimenCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s + Space.xxs) {
            row("В документе") {
                Text(RU.t("Аренда: Анна Петрова, \(Self.phone)"))
                    .font(Typo.body).foregroundStyle(Ink.text2)
            }
            Hairline()
            row("В копии") {
                HStack(spacing: 0) {
                    Text("Аренда:\u{00A0}").font(Typo.body).foregroundStyle(Ink.text)
                    TagPill(text: "[ФИО_1]")
                    Text(",\u{00A0}").font(Typo.body).foregroundStyle(Ink.text)
                    TagPill(text: "[ТЕЛЕФОН_1]")
                }
            }
        }
        .padding(.vertical, Space.m + Space.xxs)
        .padding(.horizontal, Space.l)
        .onboardingCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Образец")
    }

    /// Номер не рвётся на строки: неразрывные пробелы и дефисы.
    private static let phone = "+7\u{00A0}916\u{00A0}555\u{2011}12\u{2011}34"

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: Space.m) {
            Text(label).font(Typo.caption).foregroundStyle(Ink.text3)
                .frame(width: 88, alignment: .leading)
            content()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Метка в образце — та же плашка, что в тексте документа.
private struct TagPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typo.callout.weight(.medium))
            .foregroundStyle(Ink.accent)
            .padding(.horizontal, Space.xs + 1)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Ink.accentSoft))
    }
}

// MARK: 2 · Три шага

struct HowSteps: View {
    static let steps = [
        "Чтобы начать, достаточно будет перетащить файл в окно \(Brand.name) или вставить текст.",
        "\(Brand.name) подсветит синим всё, что скроет. Модель находит большую часть личных данных, но может что-то пропустить, поэтому результат стоит проверить: пропущенное вы сможете скрыть вручную, а лишнее вернуть.",
        "Готовую копию вы скопируете или сохраните файлом и отправите куда нужно. Исходный документ не изменится.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            ForEach(Self.steps.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: Space.m) {
                    Text("\(i + 1)")
                        .font(Typo.caption.weight(.medium))
                        .foregroundStyle(Ink.accent)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Ink.accentSoft))
                    Text(RU.t(Self.steps[i].replacingOccurrences(of: "что-то", with: "что\u{2011}то")))
                        .font(Typo.body)
                        .lineSpacing(OnboardingText.leading)
                        .foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: 3а · 3б · Установка

/// Что скачается (3а) и ход установки (3б). Строки стоят на тех же местах, меняются только значки и подписи;
/// в 3б сверху общий процент и полоса. Всё в 3б — настоящее: `Installer.status`, `progress`, `detail`, `overall`.
struct InstallCard: View {
    let installer: Installer
    let live: Bool

    var body: some View {
        VStack(spacing: 0) {
            if live {
                VStack(spacing: Space.s + Space.xxs) {
                    HStack {
                        Text(installer.isDone ? "Готово" : "Установка").font(Typo.body.weight(.medium)).foregroundStyle(Ink.text)
                        Spacer()
                        Text(RU.percent(installer.overall)).font(Typo.callout).monospacedDigit().foregroundStyle(Ink.text3)
                    }
                    ProgressBar(value: installer.overall)
                }
                .padding(EdgeInsets(top: Space.m + Space.xxs, leading: Space.l, bottom: Space.m, trailing: Space.l))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(installer.isDone ? "Установка завершена" : "Установка")
                .accessibilityValue(RU.percent(installer.overall))
                Hairline()
            }
            ForEach(Installer.Step.allCases) { step in
                if step != .runtime { Hairline() }
                row(step)
            }
        }
        .onboardingCard()
    }

    private func status(_ step: Installer.Step) -> Installer.Status { live ? installer.status[step] ?? .pending : .pending }

    private func row(_ step: Installer.Step) -> some View {
        let status = status(step)
        return HStack(spacing: Space.s + Space.xxs) {
            icon(step, status).frame(width: 14, height: 14)
            Text(step.title).font(Typo.callout)
                .foregroundStyle(live && status == .pending ? Ink.text3 : Ink.text)
            Spacer(minLength: Space.s)
            if let detail = detail(step, status), !detail.isEmpty {
                Text(detail).font(Typo.caption).monospacedDigit().foregroundStyle(Ink.text3).lineLimit(1)
            }
        }
        .padding(.horizontal, Space.l)
        .frame(height: 40)
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusName(step, status))
    }

    @ViewBuilder private func icon(_ step: Installer.Step, _ status: Installer.Status) -> some View {
        switch status {
        case .done: Glyph(kind: .check, size: 14, weight: 2.2).foregroundStyle(Ink.accent)
        case .failed: Glyph(kind: .warning, size: 14).foregroundStyle(Ink.danger)
        case .running: RingProgress(value: installer.progress[step] ?? 0, size: 13)
        case .pending: Circle().strokeBorder(Ink.strongLine).frame(width: 13, height: 13)
        }
    }

    /// До установки — что и сколько скачается; во время — подпись установщика.
    private func detail(_ step: Installer.Step, _ status: Installer.Status) -> String? {
        guard live else {
            switch step {
            case .runtime: return "≈\u{00A0}250\u{00A0}МБ"
            case .model: return RU.megabytes(Manifest.modelBytes)
            case .check: return "на тестовом тексте"
            }
        }
        return status == .pending ? nil : installer.detail[step]
    }

    private func statusName(_ step: Installer.Step, _ status: Installer.Status) -> String {
        switch status {
        case .done: "готово"
        case .failed: "ошибка"
        case .running: "идёт, \(RU.percent(installer.progress[step] ?? 0))"
        case .pending: live ? "впереди" : ""
        }
    }
}

/// Тонкая полоса прогресса акцентного цвета.
struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.line)
                Capsule().fill(Ink.accent).frame(width: max(6, geo.size.width * min(max(value, 0), 1)))
                    .animation(.easeOut(duration: 0.3), value: value)
            }
        }
        .frame(height: 5)
    }
}

// MARK: 4 · Папка

/// Выбор рабочей папки на шаге 4. По умолчанию — «Документы › Nekto». «Выбрать свою папку…» открывает панель выбора;
/// выбранная там папка сразу отмечает второй вариант и стоит под ним. Добавляется папка только по «Начать работу»:
/// до этого выбор можно поменять, и в боковой панели не остаётся лишних папок.
struct FolderChoice: Equatable {
    enum Option: Equatable { case suggested, custom }
    var option: Option = .suggested
    /// Папка из панели выбора; остаётся под вторым вариантом, даже если вернулись к первому.
    var custom: URL?

    /// Панель выбора. Отмена ничего не меняет.
    @MainActor mutating func pick(with folders: WorkFolders) {
        guard let url = folders.choose(prompt: "Выбрать", near: custom) else { return }
        custom = url
        option = .custom
    }

    @MainActor func apply(to model: AppModel) {
        if option == .custom, let custom { model.addFolder(custom) } else { model.useSuggestedFolder() }
    }
}

struct FolderCard: View {
    @Environment(AppModel.self) private var model
    @Binding var choice: FolderChoice

    var body: some View {
        VStack(spacing: 0) {
            FolderOptionRow(
                title: "Новая папка в «Документах»",
                subtitle: FolderPath.suggestedLabel,
                selected: choice.option == .suggested
            ) { choice.option = .suggested }
            Hairline()
            FolderOptionRow(
                title: "Выбрать свою папку…",
                subtitle: choice.custom.map(FolderPath.label) ?? RU.t("Любая папка на этом Mac"),
                selected: choice.option == .custom
            ) { choice.pick(with: model.folders) }
        }
        .onboardingCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Папка для документов")
    }
}

/// Вариант выбора папки: значок, название и путь, кружок выбора справа. Вся строка — кнопка.
private struct FolderOptionRow: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                FolderGlyph(selected: selected).frame(width: 22, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(selected ? Typo.body.weight(.medium) : Typo.body).foregroundStyle(Ink.text)
                    Text(subtitle).font(Typo.caption).foregroundStyle(Ink.text3)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: Space.s)
                RadioMark(selected: selected)
            }
            .padding(.horizontal, Space.l)
            .frame(height: 58)
            .contentShape(Rectangle())
            .background(hover ? Ink.hover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        // Без `accessibilityElement(children: .ignore)`: он заменяет элемент кнопки новым, и нажатие
        // (VoiceOver, AXPress) пропадает — проверено в приложении.
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Значок папки из макета (22 × 18): выбранная — залита синим, остальные — контуром.
private struct FolderGlyph: View {
    let selected: Bool
    var body: some View {
        if selected {
            FolderShape().fill(Ink.accent)
        } else {
            FolderShape().stroke(Ink.text3, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }
    }
}

private struct FolderShape: Shape {
    /// Путь значка из макета, в сетке 22 × 18.
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 1, y: 3.2))
        p.addCurve(to: CGPoint(x: 3.2, y: 1), control1: CGPoint(x: 1, y: 2), control2: CGPoint(x: 2, y: 1))
        p.addLine(to: CGPoint(x: 8, y: 1))
        p.addLine(to: CGPoint(x: 10, y: 3.4))
        p.addLine(to: CGPoint(x: 18.8, y: 3.4))
        p.addCurve(to: CGPoint(x: 21, y: 5.6), control1: CGPoint(x: 20, y: 3.4), control2: CGPoint(x: 21, y: 4.4))
        p.addLine(to: CGPoint(x: 21, y: 14.8))
        p.addCurve(to: CGPoint(x: 18.8, y: 17), control1: CGPoint(x: 21, y: 16), control2: CGPoint(x: 20, y: 17))
        p.addLine(to: CGPoint(x: 3.2, y: 17))
        p.addCurve(to: CGPoint(x: 1, y: 14.8), control1: CGPoint(x: 2, y: 17), control2: CGPoint(x: 1, y: 16))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: rect.width / 22, y: rect.height / 18).translatedBy(x: rect.minX, y: rect.minY))
    }
}

/// Кружок выбора 18 pt: выбран — синий с белой точкой, нет — тонкое кольцо.
private struct RadioMark: View {
    let selected: Bool
    var body: some View {
        ZStack {
            if selected {
                Circle().fill(Ink.accent)
                Circle().fill(.white).frame(width: 6, height: 6)
            } else {
                Circle().strokeBorder(Ink.strongLine, lineWidth: 1.5)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// Путь папки для подписи: «Документы › Проекты» — от домашней папки, с именами, как их показывает Finder.
enum FolderPath {
    /// Подпись папки по умолчанию — без обращения к диску: заглянуть в «Документы» значит вызвать запрос доступа
    /// к ним, а человек ещё ничего не выбрал. Папку из панели выбора читать можно: её выбрал сам человек.
    @MainActor static var suggestedLabel: String {
        WorkFolders.suggested == Footprint.current.suggestedFolder ? "Документы › \(Brand.name)" : label(WorkFolders.suggested)
    }

    static func label(_ url: URL) -> String {
        let fm = FileManager.default
        let path = url.standardizedFileURL.path
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var base: String
        var parts: [String]
        if path == home {
            return fm.displayName(atPath: home)
        } else if path.hasPrefix(home + "/") {
            base = home
            parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        } else {
            base = "/"
            parts = path.split(separator: "/").map(String.init)
        }
        var names: [String] = base == "/" ? [fm.displayName(atPath: "/")] : []
        for part in parts {
            base = (base as NSString).appendingPathComponent(part)
            names.append(fm.fileExists(atPath: base) ? fm.displayName(atPath: base) : part)
        }
        return names.joined(separator: " › ")
    }
}

// MARK: Подвал

/// Четыре чёрточки шагов: текущая длиннее и синяя, пройденные — синие бледнее, впереди — серые.
struct StepDashes: View {
    let current: Int

    var body: some View {
        HStack(spacing: Space.xs + Space.xxs) {
            ForEach(1...4, id: \.self) { k in
                Capsule()
                    .fill(k <= current ? Ink.accent.opacity(k == current ? 1 : 0.45) : Ink.strongLine)
                    .frame(width: k == current ? 24 : 12, height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Шаг \(current) из 4")
    }
}
