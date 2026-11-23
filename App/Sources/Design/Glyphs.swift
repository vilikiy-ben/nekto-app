import SwiftUI

/// Собственные монохромные иконки. Каждая — путь в сетке 24×24, рисуется штрихом
/// одной толщины со скруглёнными концами; заливка — только для точек и мелких деталей.
/// Цвет наследуется от `foregroundStyle`, поэтому одна и та же иконка годится для меню,
/// строки списка и кнопки панели.
enum GlyphKind: String, CaseIterable, Sendable {
    case sidebarLeft, sidebarRight, chevronLeft, chevronRight, chevronDown
    case compose, plus, paperclip, clipboard, folder, folderOpen
    case arrowUp, stop, copy, check, download, reveal, eye, restore
    case calendar, link, warning, close, more, trash, pencil, gear, shield, chip, minus
    case grip, terminal, info, building, search, fold, unfold
}

struct Glyph: View {
    let kind: GlyphKind
    var size: CGFloat = 18
    var weight: CGFloat = 1.6

    var body: some View {
        let parts = GlyphPaths.parts(kind)
        ZStack {
            if let fill = parts.fill { GlyphShape(path: fill).fill() }
            GlyphShape(path: parts.stroke)
                .stroke(style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Путь в сетке 24×24, растянутый под рамку. Толщина штриха задаётся в точках экрана.
struct GlyphShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path {
        path.applying(CGAffineTransform(a: rect.width / 24, b: 0, c: 0, d: rect.height / 24, tx: rect.minX, ty: rect.minY))
    }
}

enum GlyphPaths {
    struct Parts { var stroke: Path; var fill: Path? = nil }

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func parts(_ kind: GlyphKind) -> Parts {
        var p = Path()
        switch kind {
        case .sidebarLeft, .sidebarRight:
            // Рамка окна и перегородка во всю высоту: слева — боковая панель, справа — «Скрыто».
            p.addRoundedRect(in: CGRect(x: 3, y: 4.5, width: 18, height: 15), cornerSize: CGSize(width: 3.6, height: 3.6), style: .continuous)
            let x: CGFloat = kind == .sidebarLeft ? 9.2 : 14.8
            p.move(to: pt(x, 4.5)); p.addLine(to: pt(x, 19.5))
            return Parts(stroke: p)

        case .chevronLeft:
            p.move(to: pt(14.5, 5.5)); p.addLine(to: pt(8, 12)); p.addLine(to: pt(14.5, 18.5))
            return Parts(stroke: p)
        case .chevronRight:
            p.move(to: pt(9.5, 5.5)); p.addLine(to: pt(16, 12)); p.addLine(to: pt(9.5, 18.5))
            return Parts(stroke: p)
        case .chevronDown:
            p.move(to: pt(6.5, 9.5)); p.addLine(to: pt(12, 15)); p.addLine(to: pt(17.5, 9.5))
            return Parts(stroke: p)

        case .compose:
            p.move(to: pt(11, 4.5)); p.addLine(to: pt(7.5, 4.5))
            p.addQuadCurve(to: pt(4.5, 7.5), control: pt(4.5, 4.5))
            p.addLine(to: pt(4.5, 16.5)); p.addQuadCurve(to: pt(7.5, 19.5), control: pt(4.5, 19.5))
            p.addLine(to: pt(16.5, 19.5)); p.addQuadCurve(to: pt(19.5, 16.5), control: pt(19.5, 19.5))
            p.addLine(to: pt(19.5, 13))
            p.move(to: pt(17.2, 4.2)); p.addLine(to: pt(19.8, 6.8)); p.addLine(to: pt(12.1, 14.5))
            p.addLine(to: pt(9, 15)); p.addLine(to: pt(9.5, 11.9)); p.closeSubpath()
            return Parts(stroke: p)

        case .plus:
            p.move(to: pt(12, 5)); p.addLine(to: pt(12, 19))
            p.move(to: pt(5, 12)); p.addLine(to: pt(19, 12))
            return Parts(stroke: p)

        case .paperclip:
            // Три параллельных колена, как у настоящей скрепки.
            p.move(to: pt(15.5, 8.5)); p.addLine(to: pt(15.5, 16))
            p.addArc(center: pt(12, 16), radius: 3.5, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: pt(8.5, 6.5))
            p.addArc(center: pt(11, 6.5), radius: 2.5, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            p.addLine(to: pt(13.5, 15.5))
            p.addArc(center: pt(12, 15.5), radius: 1.5, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: pt(10.5, 9))
            return Parts(stroke: p)

        case .clipboard:
            p.move(to: pt(8.5, 5)); p.addLine(to: pt(7.5, 5))
            p.addQuadCurve(to: pt(5, 7.5), control: pt(5, 5))
            p.addLine(to: pt(5, 18.5)); p.addQuadCurve(to: pt(7.5, 21), control: pt(5, 21))
            p.addLine(to: pt(16.5, 21)); p.addQuadCurve(to: pt(19, 18.5), control: pt(19, 21))
            p.addLine(to: pt(19, 7.5)); p.addQuadCurve(to: pt(16.5, 5), control: pt(19, 5))
            p.addLine(to: pt(15.5, 5))
            p.addRoundedRect(in: CGRect(x: 8.5, y: 3, width: 7, height: 4), cornerSize: CGSize(width: 1.6, height: 1.6))
            p.move(to: pt(8.5, 12)); p.addLine(to: pt(15.5, 12))
            p.move(to: pt(8.5, 16)); p.addLine(to: pt(13, 16))
            return Parts(stroke: p)

        case .folder:
            p.move(to: pt(3.5, 17.5)); p.addLine(to: pt(3.5, 6.5)); p.addQuadCurve(to: pt(5, 5), control: pt(3.5, 5))
            p.addLine(to: pt(9.2, 5)); p.addLine(to: pt(11.2, 7.2)); p.addLine(to: pt(19, 7.2))
            p.addQuadCurve(to: pt(20.5, 8.7), control: pt(20.5, 7.2))
            p.addLine(to: pt(20.5, 17.5)); p.addQuadCurve(to: pt(19, 19), control: pt(20.5, 19))
            p.addLine(to: pt(5, 19)); p.addQuadCurve(to: pt(3.5, 17.5), control: pt(3.5, 19))
            p.move(to: pt(3.5, 10.2)); p.addLine(to: pt(20.5, 10.2))
            return Parts(stroke: p)

        case .folderOpen:
            p.move(to: pt(3.5, 17.5)); p.addLine(to: pt(3.5, 6.5)); p.addQuadCurve(to: pt(5, 5), control: pt(3.5, 5))
            p.addLine(to: pt(9.2, 5)); p.addLine(to: pt(11.2, 7.2)); p.addLine(to: pt(17, 7.2))
            p.addQuadCurve(to: pt(18.5, 8.7), control: pt(18.5, 7.2)); p.addLine(to: pt(18.5, 10.5))
            p.move(to: pt(4.3, 19)); p.addLine(to: pt(6.6, 11.6)); p.addQuadCurve(to: pt(7.9, 10.5), control: pt(6.9, 10.5))
            p.addLine(to: pt(20.2, 10.5)); p.addQuadCurve(to: pt(21.1, 11.8), control: pt(21.5, 10.5))
            p.addLine(to: pt(19.1, 18)); p.addQuadCurve(to: pt(17.8, 19), control: pt(18.8, 19))
            p.addLine(to: pt(4.3, 19)); p.addQuadCurve(to: pt(3.5, 17.5), control: pt(3.5, 19))
            return Parts(stroke: p)

        case .arrowUp:
            p.move(to: pt(12, 18.5)); p.addLine(to: pt(12, 5.5))
            p.move(to: pt(6.5, 11)); p.addLine(to: pt(12, 5.5)); p.addLine(to: pt(17.5, 11))
            return Parts(stroke: p)

        case .stop:
            var f = Path()
            f.addRoundedRect(in: CGRect(x: 7.5, y: 7.5, width: 9, height: 9), cornerSize: CGSize(width: 2, height: 2))
            return Parts(stroke: Path(), fill: f)

        case .copy:
            p.addRoundedRect(in: CGRect(x: 8.5, y: 8.5, width: 12, height: 12), cornerSize: CGSize(width: 2.8, height: 2.8), style: .continuous)
            p.move(to: pt(15.5, 5.2)); p.addQuadCurve(to: pt(13, 3.5), control: pt(15.2, 3.5))
            p.addLine(to: pt(6, 3.5)); p.addQuadCurve(to: pt(3.5, 6), control: pt(3.5, 3.5))
            p.addLine(to: pt(3.5, 13)); p.addQuadCurve(to: pt(5.2, 15.5), control: pt(3.5, 15.2))
            return Parts(stroke: p)

        case .check:
            p.move(to: pt(5, 12.5)); p.addLine(to: pt(9.8, 17.2)); p.addLine(to: pt(19, 7))
            return Parts(stroke: p)

        case .download:
            p.move(to: pt(12, 3.5)); p.addLine(to: pt(12, 14.5))
            p.move(to: pt(7.5, 10.5)); p.addLine(to: pt(12, 15)); p.addLine(to: pt(16.5, 10.5))
            p.move(to: pt(4.5, 15)); p.addLine(to: pt(4.5, 17.5)); p.addQuadCurve(to: pt(7, 20), control: pt(4.5, 20))
            p.addLine(to: pt(17, 20)); p.addQuadCurve(to: pt(19.5, 17.5), control: pt(19.5, 20)); p.addLine(to: pt(19.5, 15))
            return Parts(stroke: p)

        case .reveal:
            // «Показать в Finder»: папка с лупой, как в Загрузках Safari и вложениях Почты.
            // Стрелка из квадрата значила бы «открыть ссылку снаружи».
            p.move(to: pt(10.5, 18)); p.addLine(to: pt(5, 18)); p.addQuadCurve(to: pt(3.5, 16.5), control: pt(3.5, 18))
            p.addLine(to: pt(3.5, 6.5)); p.addQuadCurve(to: pt(5, 5), control: pt(3.5, 5))
            p.addLine(to: pt(9, 5)); p.addLine(to: pt(10.8, 7)); p.addLine(to: pt(17.5, 7))
            p.addQuadCurve(to: pt(19, 8.5), control: pt(19, 7)); p.addLine(to: pt(19, 10))
            p.addEllipse(in: CGRect(x: 12.2, y: 11.2, width: 6.6, height: 6.6))
            p.move(to: pt(17.9, 16.9)); p.addLine(to: pt(20.5, 19.5))
            return Parts(stroke: p)

        case .eye:
            p.move(to: pt(2.8, 12)); p.addCurve(to: pt(21.2, 12), control1: pt(5.8, 6), control2: pt(18.2, 6))
            p.addCurve(to: pt(2.8, 12), control1: pt(18.2, 18), control2: pt(5.8, 18))
            p.addEllipse(in: CGRect(x: 9.2, y: 9.2, width: 5.6, height: 5.6))
            return Parts(stroke: p)

        case .restore:
            // Стрелка «вернуть»: данные возвращаются на место меток.
            p.move(to: pt(19.5, 18.5)); p.addLine(to: pt(19.5, 14))
            p.addQuadCurve(to: pt(15, 9.5), control: pt(19.5, 9.5))
            p.addLine(to: pt(5.5, 9.5))
            p.move(to: pt(9.5, 5.5)); p.addLine(to: pt(5.5, 9.5)); p.addLine(to: pt(9.5, 13.5))
            return Parts(stroke: p)

        case .calendar:
            p.addRoundedRect(in: CGRect(x: 4, y: 5.5, width: 16, height: 15), cornerSize: CGSize(width: 3, height: 3), style: .continuous)
            p.move(to: pt(4, 10)); p.addLine(to: pt(20, 10))
            p.move(to: pt(8.5, 3.5)); p.addLine(to: pt(8.5, 7))
            p.move(to: pt(15.5, 3.5)); p.addLine(to: pt(15.5, 7))
            var f = Path()
            for (x, y) in [(8.5, 14.2), (12.0, 14.2), (15.5, 14.2), (8.5, 17.2)] as [(CGFloat, CGFloat)] {
                f.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
            }
            return Parts(stroke: p, fill: f)

        case .link:
            var a = Path()
            a.addRoundedRect(in: CGRect(x: 2.8, y: 9, width: 10.4, height: 6), cornerSize: CGSize(width: 3, height: 3))
            a.addRoundedRect(in: CGRect(x: 10.8, y: 9, width: 10.4, height: 6), cornerSize: CGSize(width: 3, height: 3))
            let t = CGAffineTransform(translationX: 12, y: 12).rotated(by: -.pi / 4).translatedBy(x: -12, y: -12)
            return Parts(stroke: a.applying(t))

        case .warning:
            p.move(to: pt(10.3, 4.6)); p.addQuadCurve(to: pt(13.7, 4.6), control: pt(12, 1.9))
            p.addLine(to: pt(20.6, 17)); p.addQuadCurve(to: pt(18.9, 20), control: pt(22, 20))
            p.addLine(to: pt(5.1, 20)); p.addQuadCurve(to: pt(3.4, 17), control: pt(2, 20)); p.closeSubpath()
            p.move(to: pt(12, 9.5)); p.addLine(to: pt(12, 13.5))
            var f = Path(); f.addEllipse(in: CGRect(x: 11, y: 15.6, width: 2, height: 2))
            return Parts(stroke: p, fill: f)

        case .close:
            p.move(to: pt(6.5, 6.5)); p.addLine(to: pt(17.5, 17.5))
            p.move(to: pt(17.5, 6.5)); p.addLine(to: pt(6.5, 17.5))
            return Parts(stroke: p)

        case .more:
            var f = Path()
            for x in [6.0, 12.0, 18.0] as [CGFloat] { f.addEllipse(in: CGRect(x: x - 1.5, y: 10.5, width: 3, height: 3)) }
            return Parts(stroke: Path(), fill: f)

        case .trash:
            p.move(to: pt(4.5, 6.5)); p.addLine(to: pt(19.5, 6.5))
            p.move(to: pt(9.5, 6.5)); p.addLine(to: pt(9.5, 5)); p.addQuadCurve(to: pt(10.8, 3.7), control: pt(9.5, 3.7))
            p.addLine(to: pt(13.2, 3.7)); p.addQuadCurve(to: pt(14.5, 5), control: pt(14.5, 3.7)); p.addLine(to: pt(14.5, 6.5))
            p.move(to: pt(6.5, 6.5)); p.addLine(to: pt(7.4, 18.3)); p.addQuadCurve(to: pt(9.6, 20.3), control: pt(7.6, 20.3))
            p.addLine(to: pt(14.4, 20.3)); p.addQuadCurve(to: pt(16.6, 18.3), control: pt(16.4, 20.3)); p.addLine(to: pt(17.5, 6.5))
            return Parts(stroke: p)

        case .gear:
            // Восемь зубцов по окружности и ось.
            let c = pt(12, 12)
            for t in 0..<8 {
                let a = Double(t) * .pi / 4
                let angles = [(a - 0.24, 6.9), (a - 0.13, 9.2), (a + 0.13, 9.2), (a + 0.24, 6.9)]
                for (i, (ang, r)) in angles.enumerated() {
                    let point = CGPoint(x: c.x + CGFloat(cos(ang) * r), y: c.y + CGFloat(sin(ang) * r))
                    if t == 0 && i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                }
            }
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: 9, y: 9, width: 6, height: 6))
            return Parts(stroke: p)

        case .building:
            // здание с окнами: организация
            p.addRoundedRect(in: CGRect(x: 5, y: 3.5, width: 10, height: 17), cornerSize: CGSize(width: 1.6, height: 1.6), style: .continuous)
            p.move(to: pt(15, 9)); p.addLine(to: pt(19, 9)); p.addLine(to: pt(19, 20.5)); p.addLine(to: pt(3, 20.5))
            p.move(to: pt(10, 20.5)); p.addLine(to: pt(10, 17))
            var f = Path()
            for (x, y) in [(8.0, 7.5), (12.0, 7.5), (8.0, 11.0), (12.0, 11.0), (8.0, 14.5), (12.0, 14.5)] as [(CGFloat, CGFloat)] {
                f.addRoundedRect(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6), cornerSize: CGSize(width: 0.4, height: 0.4))
            }
            return Parts(stroke: p, fill: f)

        case .shield:
            p.move(to: pt(12, 3)); p.addLine(to: pt(19.5, 6)); p.addLine(to: pt(19.5, 11.2))
            p.addCurve(to: pt(12, 21), control1: pt(19.5, 16), control2: pt(16, 19.4))
            p.addCurve(to: pt(4.5, 11.2), control1: pt(8, 19.4), control2: pt(4.5, 16))
            p.addLine(to: pt(4.5, 6)); p.closeSubpath()
            p.move(to: pt(8.6, 12)); p.addLine(to: pt(11, 14.4)); p.addLine(to: pt(15.6, 9.6))
            return Parts(stroke: p)

        case .chip:
            p.addRoundedRect(in: CGRect(x: 6.5, y: 6.5, width: 11, height: 11), cornerSize: CGSize(width: 2.4, height: 2.4), style: .continuous)
            for v in [10.0, 14.0] as [CGFloat] {
                p.move(to: pt(v, 3.5)); p.addLine(to: pt(v, 6.5)); p.move(to: pt(v, 17.5)); p.addLine(to: pt(v, 20.5))
                p.move(to: pt(3.5, v)); p.addLine(to: pt(6.5, v)); p.move(to: pt(17.5, v)); p.addLine(to: pt(20.5, v))
            }
            var f = Path()
            f.addRoundedRect(in: CGRect(x: 9.6, y: 9.6, width: 4.8, height: 4.8), cornerSize: CGSize(width: 1, height: 1))
            return Parts(stroke: p, fill: f)

        case .minus:
            p.move(to: pt(6, 12)); p.addLine(to: pt(18, 12))
            return Parts(stroke: p)

        case .search:
            // Лупа фильтра: круг и ручка, как у поля поиска macOS.
            p.addEllipse(in: CGRect(x: 4, y: 4, width: 12.5, height: 12.5))
            p.move(to: pt(14.8, 14.8)); p.addLine(to: pt(20, 20))
            return Parts(stroke: p)

        case .fold:
            // «Свернуть все»: шевроны сверху и снизу указывают на черту посередине.
            p.move(to: pt(8, 3.5)); p.addLine(to: pt(12, 7.5)); p.addLine(to: pt(16, 3.5))
            p.move(to: pt(5, 12)); p.addLine(to: pt(19, 12))
            p.move(to: pt(8, 20.5)); p.addLine(to: pt(12, 16.5)); p.addLine(to: pt(16, 20.5))
            return Parts(stroke: p)

        case .unfold:
            // «Развернуть все»: шевроны уходят от черты вверх и вниз.
            p.move(to: pt(8, 7.5)); p.addLine(to: pt(12, 3.5)); p.addLine(to: pt(16, 7.5))
            p.move(to: pt(5, 12)); p.addLine(to: pt(19, 12))
            p.move(to: pt(8, 16.5)); p.addLine(to: pt(12, 20.5)); p.addLine(to: pt(16, 16.5))
            return Parts(stroke: p)

        case .grip:
            // Шесть точек: за это место файл утаскивают в окно чата.
            var f = Path()
            for x in [9.5, 14.5] as [CGFloat] {
                for y in [6.5, 12.0, 17.5] as [CGFloat] { f.addEllipse(in: CGRect(x: x - 1.3, y: y - 1.3, width: 2.6, height: 2.6)) }
            }
            return Parts(stroke: Path(), fill: f)

        case .terminal:
            p.addRoundedRect(in: CGRect(x: 3.5, y: 4.5, width: 17, height: 15), cornerSize: CGSize(width: 3, height: 3), style: .continuous)
            p.move(to: pt(7.5, 9.5)); p.addLine(to: pt(10.5, 12)); p.addLine(to: pt(7.5, 14.5))
            p.move(to: pt(12.5, 15)); p.addLine(to: pt(16.5, 15))
            return Parts(stroke: p)

        case .info:
            // «i» в круге: подробности по нажатию.
            p.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17))
            p.move(to: pt(12, 11)); p.addLine(to: pt(12, 16.5))
            var f = Path(); f.addEllipse(in: CGRect(x: 10.9, y: 6.9, width: 2.2, height: 2.2))
            return Parts(stroke: p, fill: f)

        case .pencil:
            p.move(to: pt(15.6, 4.6)); p.addLine(to: pt(19.4, 8.4)); p.addLine(to: pt(9, 18.8))
            p.addLine(to: pt(4.5, 19.5)); p.addLine(to: pt(5.2, 15)); p.closeSubpath()
            p.move(to: pt(13.4, 6.8)); p.addLine(to: pt(17.2, 10.6))
            return Parts(stroke: p)
        }
    }
}
