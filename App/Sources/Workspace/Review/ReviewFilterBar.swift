import SwiftUI

/// Над списком «Скрыто»: фильтр значений и «свернуть / развернуть все».
///
/// В договоре 15 значений, в выгрузке CRM — сотни; найти «Петрова» пролистыванием — не проверка, а поиск.
/// Фильтр ищет по значению, его написаниям, метке («ФИО_3») и названию типа («тел» — все телефоны).
/// Пока он заполнен, совпадения видны и в свёрнутых группах. Return показывает первое совпадение в тексте,
/// Esc очищает поле. Полоса появляется, только когда список длиннее `threshold`: у короткого списка
/// она была бы шумом.
struct ReviewFilterBar: View {
    static let threshold = 6

    @Binding var query: String
    let filtering: Bool
    let allCollapsed: Bool
    let onFold: () -> Void
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.xs) {
            HStack(spacing: Space.xs + 2) {
                Glyph(kind: .search, size: 14, weight: 1.6).foregroundStyle(focused ? Ink.text2 : Ink.text3)
                TextField("Найти значение", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typo.callout)
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .onExitCommand { query = ""; focused = false }
                    .accessibilityLabel("Найти значение в списке")
                if !query.isEmpty {
                    Button { query = "" } label: { Glyph(kind: .close, size: 12, weight: 1.8) }
                        .buttonStyle(IconButtonStyle(size: 20, tint: Ink.text3))
                        .iconName("Очистить")
                        .transition(.opacity)
                }
            }
            .padding(.leading, Space.s).padding(.trailing, Space.xs)
            .frame(height: Size.compact)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Ink.hover))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(focused ? Ink.accent.opacity(0.55) : Ink.line, lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: query.isEmpty)

            Button(action: onFold) { Glyph(kind: allCollapsed ? .unfold : .fold, size: 16, weight: 1.6) }
                .buttonStyle(IconButtonStyle(size: Size.compact))
                .disabled(filtering)
                .iconName(allCollapsed ? "Развернуть все группы" : "Свернуть все группы")
        }
    }
}
