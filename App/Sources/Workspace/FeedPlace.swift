import SwiftUI

/// Где стояла лента обработки, когда человек из неё ушёл: в редактор, в другую обработку, в настройки.
///
/// Не смещение `y`, а якорь — карточка у верхнего края и насколько её верх ушёл за край. Смещение
/// не пережило бы двух вещей: ленивый стек оценивает высоты нераскрытых карточек (после возврата они другие,
/// чем были), а правка в редакторе меняет текст, а с ним и высоту карточек выше по ленте.
struct FeedPlace {
    enum Spot {
        /// У конца, как чат: новые карточки и подсказка подтягивают ленту вниз.
        case end
        /// Верх карточки `job` на `overshoot` pt выше верхнего края ленты (отрицательное — ниже).
        case item(job: UUID, overshoot: CGFloat)
    }

    let spot: Spot
    /// Сколько карточек было. Пришли новые, пока человек был в редакторе, — лента открывается с конца, у них.
    let itemCount: Int
}

/// Что лента знает о своей прокрутке, не перерисовываясь: ссылка в `@State`, а не наблюдаемые поля.
/// Рамки карточек меняются на каждом кадре прокрутки; будь они состоянием вида, лента пересобиралась бы целиком.
@MainActor
final class FeedScrollTracker {
    /// Смещение содержимого (`ScrollGeometry.contentOffset.y`).
    private(set) var offset: CGFloat = 0
    /// Лента стоит у конца (с допуском в пару точек).
    private(set) var atEnd = true
    /// Лента стоит там, где её оставили, а не у конца: подсказка под последним результатом её не утягивает.
    var holdsPlace = false
    /// Вертикальные рамки раскрытых карточек относительно верхнего края ленты. Ленивый стек раскрывает
    /// только видимые и соседние, поэтому ушедшие карточки удаляются (`forget`): их рамки устарели бы.
    private var frames: [UUID: ClosedRange<CGFloat>] = [:]

    func scrolled(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        atEnd = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 2
    }

    func placed(_ job: UUID, _ frame: CGRect) { frames[job] = frame.minY...max(frame.minY, frame.maxY) }
    func forget(_ job: UUID) { frames[job] = nil }
    func top(of job: UUID) -> CGFloat? { frames[job]?.lowerBound }

    /// Текущее место ленты. Якорь — последняя по порядку карточка, которая пересекает верхний край;
    /// если такой нет (лента в самом начале, над первой карточкой отступ), — первая видимая.
    func place(order: [UUID]) -> FeedPlace {
        if atEnd { return FeedPlace(spot: .end, itemCount: order.count) }
        let crossing = order.last { id in frames[id].map { $0.lowerBound <= 0 && $0.upperBound > 0 } ?? false }
        let below = order.first { id in frames[id].map { $0.lowerBound > 0 } ?? false }
        guard let anchor = crossing ?? below, let top = frames[anchor]?.lowerBound else {
            return FeedPlace(spot: .end, itemCount: order.count)
        }
        return FeedPlace(spot: .item(job: anchor, overshoot: -top), itemCount: order.count)
    }
}
