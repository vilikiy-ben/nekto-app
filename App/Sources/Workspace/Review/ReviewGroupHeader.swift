import AppKit
import SwiftUI

/// Заголовок группы «Скрыто»: флажок «скрывать все», название, число и сворачивание.
///
/// - Флажок стоит в той же колонке, что флажки строк: он их родитель (HIG → Toggles, смешанное состояние).
/// - Щелчок по остальной строке сворачивает группу, с ⌥ — все группы сразу, как треугольники в Finder и Почте.
///   Свёрнутость запоминается по типу (`ReviewPreferences`).
/// - Шеврон — у свёрнутой группы всегда (там скрыты строки), у раскрытой — при наведении, как у разделов
///   боковой панели Finder: столбец из девяти шевронов шумел бы. Свернуть всё можно и кнопкой над списком.
/// - Высота — компактная (28), а не как у строки (32): заголовок группирует, а не спорит со строками.
/// - Правый щелчок и «Действия» VoiceOver — те же действия, что мышью (`RowAction`).
struct ReviewGroupHeader: View {
    @Environment(AppModel.self) private var model
    let group: DocumentReview.Group
    let collapsed: Bool
    let processing: Processing
    /// Все группы панели, которые сворачиваются: для ⌥-щелчка и «Свернуть остальные».
    let collapsibleKinds: [String]
    var gapAbove: CGFloat = 0
    @State private var hover = false

    static let height: CGFloat = Size.compact

    static func scrollID(_ kind: String) -> String { "group:" + kind }

    private var title: String { KindNames.title(group.kind) }
    private var collapsible: Bool { !group.entries.isEmpty }

    var body: some View {
        HStack(spacing: Space.s + 2) {
            Button { model.toggleGroup(group, in: processing) } label: {
                Checkbox(state: group.check)
                    .opacity(group.locked ? 0.7 : 1)
                    .frame(width: Size.compact - 4, height: Self.height).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, -Space.xs)
            .accessibilityLabel("Скрывать все: \(title)")
            .accessibilityValue(checkValue)
            .accessibilityHint(checkHint)

            Button(action: toggleCollapsed) {
                HStack(spacing: Space.s) {
                    // Уступает место подпись, а не название и не число: «Организации 2» важнее, чем «не скрываются».
                    Text(title).font(Typo.callout.weight(.semibold)).foregroundStyle(Ink.text2)
                        .lineLimit(1).layoutPriority(2)
                    Text(countLabel).font(Typo.callout).monospacedDigit().foregroundStyle(Ink.text3)
                        .contentTransition(.numericText())
                        .fixedSize().layoutPriority(2)
                    if let note = group.note {
                        Text(note).font(Typo.caption).foregroundStyle(Ink.text3).lineLimit(1)
                            .truncationMode(.tail)
                            .transition(.opacity)
                    }
                    Spacer(minLength: Space.xs)
                    if collapsible {
                        Glyph(kind: .chevronDown, size: 11, weight: 1.8)
                            .foregroundStyle(hover ? Ink.text2 : Ink.text3)
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                            .frame(width: 16)
                            .opacity(collapsed || hover ? 1 : 0)
                    }
                }
                .frame(height: Self.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(collapsible)
            .accessibilityLabel(title)
            .accessibilityValue(collapsible ? (collapsed ? "свёрнута" : "развёрнута") : (group.note ?? ""))
            .accessibilityHint(collapsible ? "Свернуть или развернуть группу. С Option — все группы" : "")
        }
        .animation(.easeOut(duration: 0.15), value: group.note)
        .animation(.snappy(duration: 0.2), value: collapsed)
        .padding(.horizontal, Space.s + 2)
        .background(RowBackground(selected: false, hover: hover || tagInside))
        .onHover { hover = $0 }
        .padding(.top, gapAbove)
        .rowContextMenu(actions)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
        .rowAccessibilityActions(actions)
    }

    /// Курсор над меткой этой группы в тексте, а строки не видно — подсвечен заголовок.
    private var tagInside: Bool {
        guard collapsed, let tag = model.hoveredTag else { return false }
        return processing.byPlaceholder[tag]?.kind == group.kind
    }

    /// «4», а если скрыта только часть — «3 из 4»: смешанный флажок говорит «не все», число — сколько.
    private var countLabel: String {
        group.check == .mixed ? "\(group.hidden) из \(group.entries.count)" : group.entries.isEmpty ? "" : "\(group.entries.count)"
    }

    private func toggleCollapsed() {
        guard collapsible else { return }
        let prefs = model.reviewPrefs
        withAnimation(.snappy(duration: 0.22)) {
            if NSEvent.modifierFlags.contains(.option) {
                prefs.setCollapsed(collapsibleKinds, !collapsed)
            } else {
                prefs.toggleCollapsed(group.kind)
            }
        }
    }

    // MARK: Действия

    private var actions: [RowAction] {
        let prefs = model.reviewPrefs
        var list: [RowAction] = []
        if collapsible {
            list.append(RowAction(title: collapsed ? "Развернуть" : "Свернуть") { toggleCollapsed() })
            let others = collapsibleKinds.filter { $0 != group.kind }
            if !others.isEmpty {
                list.append(RowAction(title: "Свернуть остальные") {
                    withAnimation(.snappy(duration: 0.22)) {
                        prefs.setCollapsed(others, true)
                        prefs.setCollapsed([group.kind], false)
                    }
                })
            }
            list.append(RowAction(title: "Развернуть все") {
                withAnimation(.snappy(duration: 0.22)) { prefs.setCollapsed(collapsibleKinds, false) }
            })
        }
        list.append(RowAction(title: toggleTitle, separatorBefore: !list.isEmpty) { model.toggleGroup(group, in: processing) })
        return list
    }

    /// Что сделает флажок — тем же языком, что «Отменить …» в меню «Правка».
    private var toggleTitle: String {
        switch group.check {
        case .on: group.mode.map(\.revealTitle) ?? "Не скрывать все «\(title)»"
        case .off where group.locked: group.mode.map(\.hideTitle) ?? "Скрывать все «\(title)»"
        default: "Скрывать все «\(title)»"
        }
    }

    private var checkValue: String {
        switch group.check {
        case .on: "скрываются все"
        case .mixed: "скрываются \(group.hidden) из \(group.entries.count)"
        case .off: group.locked ? "тип не скрывается" : "не скрывается ни одно"
        }
    }

    private var checkHint: String {
        if let mode = group.mode, group.check == .on { return mode.unhideHint }
        return group.mode != nil ? "Действует на все документы обработки, включая новые" : "Действует на все значения группы во всех документах обработки"
    }
}
