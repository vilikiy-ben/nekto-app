import AppKit
import SwiftUI

/// Действие строки списка (обработка, папка). Одно описание — для кнопки «…», правого щелчка и VoiceOver:
/// HIG (Context menus) — действия контекстного меню должны быть доступны и другим способом, и меню должны совпадать.
struct RowAction: Identifiable {
    let title: String
    /// Удаляет данные: красный пункт, как у системных меню с опасным действием.
    var destructive = false
    /// Разделитель перед пунктом: опасное действие стоит отдельной группой в конце.
    var separatorBefore = false
    let perform: () -> Void

    var id: String { title }
}

extension View {
    /// Правый щелчок: те же пункты и в том же порядке, что у «…».
    func rowContextMenu(_ actions: [RowAction]) -> some View {
        contextMenu {
            ForEach(actions) { action in
                if action.separatorBefore { Divider() }
                if action.destructive {
                    // Роль сама по себе пункт контекстного меню macOS не красит — цвет задаётся тексту.
                    Button(role: .destructive, action: action.perform) { Text(action.title).foregroundStyle(Ink.danger) }
                } else {
                    Button(action.title, action: action.perform)
                }
            }
        }
    }

    /// Те же действия для VoiceOver («Действия» в роторе): «…» видна только при наведении, а клавиатуре и VoiceOver
    /// наведение недоступно (HIG: Accessibility — у каждого действия должен быть путь без мыши).
    func rowAccessibilityActions(_ actions: [RowAction]) -> some View {
        accessibilityActions {
            ForEach(actions) { action in Button(action.title, action: action.perform) }
        }
    }
}

/// Кнопка «…» в строке списка.
///
/// Ведёт себя как системная кнопка с выпадающим меню (HIG: Pull-down buttons):
/// - меню открывается по нажатию, а не по отпусканию: можно нажать, повести к пункту и отпустить;
/// - у кнопки три состояния — наведение, нажатие и «меню открыто» (подложка плотнее, значок ярче),
///   и пока меню открыто, кнопка остаётся на месте и подсвечена, а строка — выделена (`isOpen`);
/// - меню — настоящее `NSMenu`: клавиши со стрелками, поиск по первой букве, Esc, VoiceOver.
///
/// Рисует кнопку SwiftUI, а нажатия принимает прозрачный `NSView` поверх: только у него есть mouseDown,
/// во время которого меню начинает слежение за мышью.
struct RowMoreButton: View {
    /// Имя для VoiceOver: «Действия с обработкой», «Действия с папкой».
    let label: String
    /// Кнопка видна и нажимается. Невидимая занимает своё место (строка не прыгает) и пропускает щелчки к строке.
    let visible: Bool
    let actions: () -> [RowAction]
    @Binding var isOpen: Bool
    /// Курсор над самой кнопкой: строка держит её видимой, даже если её собственное наведение сбросилось.
    @Binding var isHovered: Bool
    @State private var pressed = false

    static let size: CGFloat = 24

    var body: some View {
        IconChrome(size: Self.size, hover: isHovered, pressed: pressed || isOpen) {
            Glyph(kind: .more, size: 15)
        }
        .opacity(visible || isOpen ? 1 : 0)
        .accessibilityHidden(true)
        .overlay {
            MenuTrigger(label: label, enabled: visible || isOpen, actions: actions,
                        onHover: { isHovered = $0 }, onPress: { pressed = $0 }, onOpen: { isOpen = $0 })
        }
    }
}

/// Прозрачная область нажатия: открывает меню по mouseDown и сообщает состояния кнопке.
private struct MenuTrigger: NSViewRepresentable {
    let label: String
    let enabled: Bool
    let actions: () -> [RowAction]
    let onHover: (Bool) -> Void
    let onPress: (Bool) -> Void
    let onOpen: (Bool) -> Void

    func makeNSView(context: Context) -> MenuTriggerView { MenuTriggerView() }

    func updateNSView(_ view: MenuTriggerView, context: Context) {
        view.label = label
        view.enabled = enabled
        view.actions = actions
        view.onHover = onHover
        view.onPress = onPress
        view.onOpen = onOpen
        view.setAccessibilityLabel(label)
    }
}

final class MenuTriggerView: NSView {
    var label = ""
    var enabled = true
    var actions: () -> [RowAction] = { [] }
    var onHover: (Bool) -> Void = { _ in }
    var onPress: (Bool) -> Void = { _ in }
    var onOpen: (Bool) -> Void = { _ in }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    // Невидимая кнопка пропускает щелчок к строке под ней.
    override func hitTest(_ point: NSPoint) -> NSView? { enabled ? super.hitTest(point) : nil }
    // Окно не в фокусе — первый же щелчок открывает меню, как у системных кнопок.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        // Кнопка могла появиться прямо под курсором — тогда входа не будет. Не посреди обновления представлений.
        DispatchQueue.main.async { [weak self] in self?.reportHover() }
    }

    override func mouseEntered(with event: NSEvent) { if enabled { onHover(true) } }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return super.mouseDown(with: event) }
        open()
    }

    // MARK: Доступность: кнопка с меню

    override func isAccessibilityElement() -> Bool { enabled }
    override func accessibilityRole() -> NSAccessibility.Role? { .menuButton }
    override func accessibilityPerformPress() -> Bool { open(); return true }

    private func open() {
        let items = actions()
        guard !items.isEmpty else { return }
        onPress(true)
        onOpen(true)
        // Подложка нажатия должна успеть нарисоваться до того, как меню начнёт слежение за мышью.
        CATransaction.flush()
        let menu = NSMenu.rowMenu(items)
        // Под кнопкой, по её левому краю, с зазором — как у выпадающего меню системной кнопки.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        onPress(false)
        onOpen(false)
        reportHover()
    }

    /// Пока меню было открыто, выход курсора мог потеряться: сверяем по месту курсора сейчас.
    private func reportHover() {
        guard let window else { return }
        let inside = enabled && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        onHover(inside)
    }
}

extension NSMenu {
    /// Меню строки: пункты по порядку, разделители, опасный пункт красным.
    static func rowMenu(_ actions: [RowAction]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in actions {
            if action.separatorBefore { menu.addItem(.separator()) }
            let handler = MenuHandler(action.perform)
            let item = NSMenuItem(title: action.title, action: #selector(MenuHandler.run), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler   // target у пункта слабый: обработчик держит сам пункт
            if action.destructive {
                item.attributedTitle = NSAttributedString(string: action.title, attributes: [
                    .foregroundColor: Ink.nsDanger, .font: NSFont.menuFont(ofSize: 0),
                ])
            }
            menu.addItem(item)
        }
        return menu
    }
}

private final class MenuHandler: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
    @objc func run() { perform() }
}
