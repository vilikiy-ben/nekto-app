import SwiftUI

/// Колонка, у которой по центру контейнера стоит не вся группа, а средний элемент — якорь.
/// Сверху над ним — заголовок, снизу — то, что под ним (может отсутствовать).
///
///     AnchoredColumn(above: 28, below: 16, top: 64, bottom: 16) { заголовок; якорь; низ }
///
/// Главный экран: строка ввода ровно посередине окна, как у чат-приложений. Если низу не хватает места
/// (низкое окно), якорь поднимается ровно настолько, насколько нужно, но заголовок не заходит выше `top`.
/// Ширина детей — их собственная (рамка колонки задаётся у самих детей), по горизонтали — по центру.
struct AnchoredColumn: Layout {
    /// Отступ между заголовком и якорем.
    var above: CGFloat
    /// Отступ между якорем и низом.
    var below: CGFloat
    /// Сверху не заходить выше (панель инструментов).
    var top: CGFloat
    /// Снизу оставить хотя бы столько.
    var bottom: CGFloat
    /// По центру — не середина якоря, а середина его нижней полосы этой высоты. Строка ввода с файлами
    /// растёт вверх, а её нижний ряд остаётся на месте: карточка вырастает из строки, а не сдвигает её.
    var anchorRow: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let natural = heights.reduce(0, +) + above + (heights.count > 2 ? below : 0) + top + bottom
        // Занимаем всю предложенную высоту: центр считается от неё.
        return CGSize(width: width, height: max(proposal.height ?? natural, natural))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let offer = ProposedViewSize(width: bounds.width, height: nil)
        let header = subviews[0].sizeThatFits(offer).height
        let anchor = subviews[1].sizeThatFits(offer).height
        let footer = subviews.count > 2 ? subviews[2].sizeThatFits(offer).height + below : 0

        let row = min(anchorRow ?? anchor, anchor)
        var anchorTop = bounds.midY - anchor + row / 2
        anchorTop = min(anchorTop, bounds.maxY - bottom - footer - anchor)   // низ помещается
        anchorTop = max(anchorTop, bounds.minY + top + header + above)       // заголовок не под панелью

        subviews[0].place(at: CGPoint(x: bounds.midX, y: anchorTop - above), anchor: .bottom, proposal: offer)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: anchorTop), anchor: .top, proposal: offer)
        if subviews.count > 2 {
            subviews[2].place(at: CGPoint(x: bounds.midX, y: anchorTop + anchor + below), anchor: .top, proposal: offer)
        }
    }
}
