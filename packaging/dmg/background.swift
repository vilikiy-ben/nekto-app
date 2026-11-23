// Фон окна установочного образа Nekto.dmg: тёплая бумага, синяя дуга от приложения к «Программам»,
// пунктирная площадка под цель и подпись SF Pro. Пишет background.png (1×) и background@2x.png (2×);
// dmgbuild склеивает их в один HiDPI TIFF.
//
//   swift packaging/dmg/background.swift packaging/dmg Nekto
//
// Имя приложения в подписи — второй аргумент (APP_NAME из scripts/brand.sh).
//
// Геометрия согласована с settings.py (Layout ниже ↔ icon_locations и window_rect).
// Подписи под значками Finder рисует сам и при картинке-фоне всегда чёрным — даже в тёмной теме,
// поэтому фон светлый в обеих темах, а цвета взяты из светлой палитры приложения (Theme.swift → Ink).
import AppKit

enum Layout {
    static let size = CGSize(width: 660, height: 400)
    static let iconSize: CGFloat = 128
    static let app = CGPoint(x: 180, y: 176)          // центр значка Nekto.app
    static let target = CGPoint(x: 480, y: 176)       // центр ярлыка «Программы»
}

enum Palette {
    static let paperTop = NSColor(srgbHex: 0xFDFCFA)      // Ink.canvas
    static let paperBottom = NSColor(srgbHex: 0xF1EEE8)   // к низу — тон плитки иконки (#ECE8E1)
    static let text = NSColor(srgbHex: 0x1D1C1A)          // Ink.text
    static let text2 = NSColor(srgbHex: 0x6B6862)         // Ink.text2
    static let accent = NSColor(srgbHex: 0x1F63EC)        // Ink.accent
}

extension NSColor {
    convenience init(srgbHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: Рисование (точки, начало координат сверху слева)

func drawPaper(in ctx: CGContext) {
    let colors = [Palette.paperTop.cgColor, Palette.paperBottom.cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: Layout.size.height), options: [])
}

/// Площадка под «Программы»: пунктирная рамка со скруглением как у плитки иконки — «бросьте сюда».
/// Охватывает значок вместе с подписью: Finder ставит центр значка в icon_locations, подпись — на ~83 pt ниже
/// (замерено в Finder macOS 27 при icon_size 128 и text_size 13).
func drawDropZone(in ctx: CGContext) {
    let rect = CGRect(x: Layout.target.x - 82, y: Layout.target.y - 72, width: 164, height: 182)
    let path = CGPath(roundedRect: rect, cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setFillColor(Palette.text.withAlphaComponent(0.025).cgColor)
    ctx.fillPath()
    ctx.addPath(path)
    ctx.setStrokeColor(Palette.text.withAlphaComponent(0.16).cgColor)
    ctx.setLineWidth(1.5)
    ctx.setLineDash(phase: 0, lengths: [5, 6])
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

/// Дуга от приложения к цели: квадратичная кривая над линией значков, наконечник по касательной.
func drawArrow(in ctx: CGContext) {
    let gap = Layout.iconSize / 2 + 26
    let start = CGPoint(x: Layout.app.x + gap, y: Layout.app.y + 4)
    let end = CGPoint(x: Layout.target.x - gap - 6, y: Layout.target.y + 4)
    let control = CGPoint(x: (start.x + end.x) / 2, y: Layout.app.y - 34)

    ctx.saveGState()
    ctx.setStrokeColor(Palette.accent.cgColor)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    ctx.move(to: start)
    ctx.addQuadCurve(to: end, control: control)
    ctx.strokePath()

    // Касательная в конце кривой — направление от контрольной точки к концу.
    let angle = atan2(end.y - control.y, end.x - control.x)
    let wing: CGFloat = 11, spread: CGFloat = .pi / 5
    for side in [-1.0, 1.0] as [CGFloat] {
        let a = angle + .pi + side * spread
        ctx.move(to: end)
        ctx.addLine(to: CGPoint(x: end.x + wing * cos(a), y: end.y + wing * sin(a)))
    }
    ctx.strokePath()
    ctx.restoreGState()
}

func drawCaption() {
    let nbsp = "\u{00A0}"
    let lines: [(String, NSFont, NSColor, CGFloat)] = [
        ("Перетащите \(appName) в\(nbsp)папку «Программы»", .systemFont(ofSize: 15, weight: .medium), Palette.text, 318),
        ("Документы обрабатываются только на\(nbsp)этом Mac", .systemFont(ofSize: 12), Palette.text2, 344),
    ]
    for (string, font, color, y) in lines {
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: -0.1])
        let size = text.size()
        text.draw(at: CGPoint(x: (Layout.size.width - size.width) / 2, y: y - size.height / 2))
    }
}

// MARK: Вывод

func render(scale: CGFloat) -> Data {
    let width = Int(Layout.size.width * scale), height = Int(Layout.size.height * scale)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Переворачиваем в координаты «сверху вниз», как у Finder и icon_locations.
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: scale, y: -scale)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    drawPaper(in: ctx)
    drawDropZone(in: ctx)
    drawArrow(in: ctx)
    drawCaption()
    NSGraphicsContext.restoreGraphicsState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = Layout.size   // 72 dpi у 1× и 144 dpi у 2× — tiffutil -cathidpicheck проверяет именно это
    return rep.representation(using: .png, properties: [:])!
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let appName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Nekto"
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] as [(CGFloat, String)] {
    let url = outDir.appendingPathComponent(name)
    try render(scale: scale).write(to: url)
    print("dmg background → \(url.path)")
}
