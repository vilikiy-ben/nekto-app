import SwiftUI

/// Собственный флажок: скруглённый квадрат акцентного цвета с галочкой, а у флажка над группой — ещё и
/// «смешанное» состояние с чёрточкой, как у системного (HIG → Toggles: флажок, который управляет другими,
/// показывает смешанное состояние, когда они включены не все).
struct Checkbox: View {
    let state: DocumentReview.Check

    init(on: Bool) { state = on ? .on : .off }
    init(state: DocumentReview.Check) { self.state = state }

    var body: some View {
        let filled = state != .off
        ZStack {
            RoundedRectangle(cornerRadius: Radius.small - 1, style: .continuous)
                .fill(filled ? Ink.accent : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: Radius.small - 1, style: .continuous)
                    .strokeBorder(filled ? Color.clear : Ink.strongLine, lineWidth: 1.2))
            switch state {
            case .on: Glyph(kind: .check, size: 12, weight: 2.2).foregroundStyle(.white)
            case .mixed: Glyph(kind: .minus, size: 12, weight: 2.2).foregroundStyle(.white)
            case .off: EmptyView()
            }
        }
        .frame(width: 16, height: 16)
        .animation(.easeOut(duration: 0.12), value: state)
    }
}
