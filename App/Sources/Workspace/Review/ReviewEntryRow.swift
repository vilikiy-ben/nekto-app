import SwiftUI

/// Значение и его метка в одну строку: значение слева, метка справа серым — как «Wi-Fi … Домашняя сеть».
/// Флажок — «скрывать»; сняли — модель ошиблась, это не персональные данные.
/// Щелчок по самой строке показывает значение в тексте.
/// `locked` — тип целиком не скрывается по флажку группы: флажок строки снят и не нажимается,
/// а её собственное решение ждёт и вернётся, когда тип снова скроют.
struct ReviewEntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: MappingEntry
    let hidden: Bool
    let locked: Bool
    let processing: Processing
    let job: Job
    @State private var hover = false

    var body: some View {
        HStack(spacing: Space.s + 2) {
            Button { model.setHidden(entry.placeholder, !hidden, in: processing) } label: {
                Checkbox(on: hidden).frame(width: Size.compact - 4, height: Size.row).contentShape(Rectangle())
                    .opacity(locked ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .padding(.leading, -Space.xs)
            .accessibilityLabel(entry.original)
            .accessibilityValue(hidden ? "скрыто" : "не скрывается")
            .accessibilityHint(locked ? "Тип не скрывается целиком — флажок в заголовке группы"
                                      : "Переключает, скрывать ли это значение во всех документах обработки")

            Button { model.spotlight(job.spotlightTarget(for: entry)) } label: {
                HStack(spacing: Space.s) {
                    Text(entry.original).font(Typo.callout).foregroundStyle(hidden ? Ink.text : Ink.text2)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: Space.xs)
                    Text(entry.placeholder.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
                        .font(Typo.mono(11, .medium)).foregroundStyle(hidden ? Ink.text2 : Ink.text3)
                        .strikethrough(!hidden, color: Ink.text3)
                        .lineLimit(1).fixedSize()
                }
                .animation(.easeOut(duration: 0.15), value: hidden)
                .frame(height: Size.row)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Показать «\(entry.original)» в тексте")
        }
        .padding(.horizontal, Space.s + 2)
        .background(RowBackground(selected: false, hover: hover || model.hoveredTag == entry.placeholder))
        .onHover { hover = $0 }
    }
}
