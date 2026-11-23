import AppKit
import SwiftUI

/// Кольцо прогресса для строк истории и шагов установки.
struct RingProgress: View {
    var value: Double
    var size: CGFloat = 14
    var indeterminate = false
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Ink.line, lineWidth: 2)
            Circle().trim(from: 0, to: indeterminate ? 0.28 : max(0.06, min(value, 1)))
                .stroke(Ink.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(indeterminate ? (spin ? 270 : -90) : -90))
                .animation(indeterminate ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .easeOut(duration: 0.3),
                           value: indeterminate ? AnyHashable(spin) : AnyHashable(value))
        }
        .frame(width: size, height: size)
        .onAppear { if indeterminate { spin = true } }
        .accessibilityElement()
        .accessibilityValue(Text(indeterminate ? "Идёт обработка" : "\(Int(value * 100)) процентов"))
    }
}

/// Иконка без рамки; при наведении появляется подложка. Для действий под результатом и в панелях.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var tint: Color = Ink.text2
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, tint: tint)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let tint: Color
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        IconChrome(size: size, tint: tint, hover: hover, pressed: configuration.isPressed, enabled: enabled) {
            configuration.label
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Вид значка-кнопки — один на всё приложение: панели, стрелки, «+», «…», «Новая обработка» в строке папки.
///
/// Наведение — подложка `controlHover`, нажатие (и открытое меню у «…») — плотнее, `controlPressed`, и значок
/// чуть сжимается (без сжатия при «Уменьшить движение»). Подложки плотнее, чем подсветка строки (`hover`, `selected`):
/// значок в подсвеченной строке тоже должен заметно отвечать. Скругление — по размеру: 24 и меньше — 6
/// (концентрично строке 32 со скруглением 10), больше — 8.
struct IconChrome<Label: View>: View {
    let size: CGFloat
    var tint: Color = Ink.text2
    let hover: Bool
    let pressed: Bool
    var enabled = true
    @ViewBuilder let label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .foregroundStyle(enabled ? (hover || pressed ? Ink.text : tint) : Ink.text3)
            .frame(minWidth: size, minHeight: size)
            .background(RoundedRectangle(cornerRadius: size <= 26 ? Radius.small : Radius.control, style: .continuous)
                .fill(!enabled ? .clear : pressed ? Ink.controlPressed : hover ? Ink.controlHover : .clear))
            .scaleEffect(pressed && !reduceMotion ? 0.9 : 1)
            .animation(.snappy(duration: 0.14), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Строка списка (боковая панель, меню): скруглённая подложка при наведении и выборе.
struct RowBackground: View {
    var selected: Bool
    var hover: Bool
    var radius: CGFloat = Radius.row
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(selected ? Ink.selected : (hover ? Ink.hover : .clear))
    }
}

/// Подпись о фоновой работе, которая обычно незаметна (обновление после правки): появляется, только если
/// работа идёт дольше полсекунды. Встаёт на место `resting` (например, счётчика) растворением: ширина берётся
/// по большему из двух, поэтому ничего рядом не сдвигается и не уступает место.
struct SlowWorkHint<Resting: View>: View {
    let active: Bool
    let text: String
    @ViewBuilder var resting: Resting
    @State private var visible = false

    var body: some View {
        ZStack(alignment: .trailing) {
            resting.opacity(visible ? 0 : 1)
            HStack(spacing: Space.xs + 2) {
                ProgressView().controlSize(.mini)
                Text(text).font(Typo.caption).foregroundStyle(Ink.text3).fixedSize()
            }
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
        }
        .animation(.easeOut(duration: 0.2), value: visible)
        .task(id: active) {
            guard active else { visible = false; return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { visible = true }
        }
    }
}

extension SlowWorkHint where Resting == EmptyView {
    init(active: Bool, text: String) { self.init(active: active, text: text) { EmptyView() } }
}

/// Текст, по которому пробегает блик, пока идёт работа (как «Думаю…» в чатах с нейросетью).
/// С «Уменьшить движение» блика нет: рядом крутится кольцо — системный знак работы.
struct ShimmerText: View {
    let text: String
    var font: Font = Typo.body
    @State private var phase: CGFloat = -0.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            HStack(spacing: Space.s) {
                RingProgress(value: 0, size: 12, indeterminate: true)
                Text(text).font(font).foregroundStyle(Ink.text2)
            }
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(Ink.text3)
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Ink.text, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.5)
                            .offset(x: phase * geo.size.width * 1.6)
                    }
                    .mask(Text(text).font(font))
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
                }
                .accessibilityLabel(text)
        }
    }
}

/// Капсула режима в строке ввода: «Даты видны ×». Кнопка: нажимается и с клавиатуры, и VoiceOver.
///
/// `compact` — только значок: режимы запоминаются для новых обработок (`ReviewPreferences`), и две-три капсулы
/// с подписями сжимали поле ввода до обрывка подсказки. Значок без подписи получает имя системной подсказкой
/// и для VoiceOver (`iconName`), как все значки приложения.
struct ModeChip: View {
    let title: String
    /// Что вернёт щелчок: «Снова скрывать даты». Подпись капсулы описывает состояние, а не действие.
    let action: String
    let glyph: GlyphKind
    var tint: Color = Ink.accent
    var compact = false
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: remove) {
            HStack(spacing: Space.xs) {
                Glyph(kind: hover ? .close : glyph, size: 14, weight: 1.6)
                if !compact { Text(title).font(Typo.callout.weight(.medium)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? 0 : Space.s + 1)
            .frame(minWidth: Size.compact, minHeight: Size.compact, maxHeight: Size.compact)
            .background(Capsule().fill(tint.opacity(hover ? 0.18 : 0.11)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .modifier(ChipName(compact: compact, title: title, action: action))
    }
}

private struct ChipName: ViewModifier {
    let compact: Bool
    let title: String
    let action: String
    func body(content: Content) -> some View {
        if compact {
            content.iconName("\(title). \(action)")
        } else {
            content.accessibilityLabel(title).accessibilityHint(action)
        }
    }
}

/// Кнопка действия с подписью: «Скопировать», «Повторить». Капсула с тонкой рамкой,
/// значок слева. `prominent` — главная кнопка группы: заливка вместо рамки, без акцентного цвета,
/// чтобы синий оставался за метками.
struct ActionButtonStyle: ButtonStyle {
    var prominent = false
    /// Действие выполнено («Скопировано»): заливка на миг становится зелёной.
    var confirmed = false
    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(configuration: configuration, prominent: prominent, confirmed: confirmed)
    }
}

private struct ActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let confirmed: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    /// `Button(role: .destructive)` — тот же вид, но красный: текст, рамка и подсветка. По роли, а не флагом,
    /// чтобы разрушительное действие нельзя было оформить как обычное (HIG, Buttons: Destructive → системный красный).
    private var destructive: Bool { configuration.role == .destructive }

    var body: some View {
        configuration.label
            .font(Typo.callout.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, Space.m).frame(height: Size.compact + 2)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .onHover { hover = $0 && enabled }
    }

    private var foreground: Color {
        guard enabled else { return Ink.text3 }
        if prominent || confirmed { return Ink.canvas }
        return destructive ? Ink.danger : Ink.text
    }

    private var fill: Color {
        if confirmed { return Ink.restored }
        if prominent { return Ink.text.opacity(hover ? 0.86 : 1) }
        guard hover else { return .clear }
        // Не `Ink.hover`: на приподнятой поверхности (карточки, настройки) 5 % почти не видны.
        return destructive ? Ink.danger.opacity(0.12) : Ink.selected
    }

    /// При наведении рамка плотнее: отклик видно и там, где заливка сливается с фоном.
    private var border: Color {
        if prominent { return .clear }
        if destructive && enabled { return Ink.danger.opacity(hover ? 0.8 : 0.5) }
        return hover ? Ink.text3 : Ink.strongLine
    }
}

/// Главная кнопка экрана: капсула акцентного цвета.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.body.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, Space.xl).frame(height: 40)
            .background(Capsule().fill(Ink.accent))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Capsule())
    }
}

/// Второстепенная кнопка: капсула с тонкой рамкой.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration)
    }
}

private struct SecondaryBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    var body: some View {
        configuration.label
            .font(Typo.body.weight(.medium))
            .foregroundStyle(Ink.text)
            .padding(.horizontal, Space.xl).frame(height: 40)
            .background(Capsule().fill(hover ? Ink.hover : .clear))
            .overlay(Capsule().strokeBorder(Ink.strongLine))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
            .onHover { hover = $0 }
    }
}

extension View {
    /// Имя значка без подписи: системная подсказка при наведении (задержка и вид — как во всей macOS,
    /// с настройкой пользователя) и подпись для VoiceOver. Других подсказок при наведении в приложении нет:
    /// подсказку получают только значки без общепринятого смысла.
    func iconName(_ name: String) -> some View {
        systemToolTip(name).accessibilityLabel(name)
    }

    /// Системная подсказка AppKit (`NSView.toolTip`) ровно по рамке этого элемента.
    ///
    /// Не SwiftUI `.help`: в панели инструментов она ставится на весь `NSToolbarItem`, и у стрелки «‹»
    /// всплывало «Скрыть боковую панель» (переключатель и стрелки — один элемент); в прокручиваемой ленте
    /// подсказка у значка Finder не появлялась вовсе. Проверено на чистой macOS.
    func systemToolTip(_ text: String) -> some View {
        background(ToolTipArea(text: text))
    }
}

/// Прозрачный слой под элементом: только подсказка, щелчки проходят к самому элементу.
private struct ToolTipArea: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
