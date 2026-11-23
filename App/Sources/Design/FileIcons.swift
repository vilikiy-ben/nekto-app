import SwiftUI

/// Цветные значки документов: лист с загнутым углом, свой цвет у каждого семейства форматов
/// и белая пометка, по которой тип узнаётся без подписи. Используются в меню «+», в строке ввода
/// и в ленте обработки — везде, где пользователь видит файл.
enum FileKind: Sendable {
    case document, pdf, sheet, slides, text, code, mail, image, folder, reply

    init(url: URL) { self.init(extension: url.pathExtension) }

    init(extension ext: String) {
        switch ext.lowercased() {
        case "docx", "docm", "dotx", "doc", "rtf", "rtfd", "odt", "wordml", "pages": self = .document
        case "pdf": self = .pdf
        case "csv", "tsv", "xlsx", "xlsm", "xltx", "xls", "numbers": self = .sheet
        case "pptx", "pptm", "potx", "ppt", "key": self = .slides
        case "eml": self = .mail
        case "json", "jsonl", "ndjson", "xml", "html", "htm", "py", "js", "ts", "swift", "sql", "yaml", "yml", "log":
            self = .code
        case let e where Importer.imageTypes.contains(e): self = .image
        default: self = .text
        }
    }

    /// Верх и низ градиента листа.
    var colors: (Color, Color) {
        switch self {
        case .document: (Color(hex: 0x4A8BFF), Color(hex: 0x2459DB))
        case .pdf: (Color(hex: 0xF7665F), Color(hex: 0xCC3631))
        case .sheet: (Color(hex: 0x37C176), Color(hex: 0x168A4B))
        case .slides: (Color(hex: 0xFFB24A), Color(hex: 0xE57A14))
        case .text: (Color(hex: 0x9EA2A8), Color(hex: 0x6B6F76))
        case .code: (Color(hex: 0x9B7DFF), Color(hex: 0x6545E0))
        case .mail: (Color(hex: 0x45C3FA), Color(hex: 0x1A8CD8))
        case .image: (Color(hex: 0x5DB8FF), Color(hex: 0x2F7FE6))
        case .folder: (Color(hex: 0x7CC4FF), Color(hex: 0x3C93F0))
        case .reply: (Color(hex: 0x40D483), Color(hex: 0x1A9A55))
        }
    }
}

struct FileIcon: View {
    let kind: FileKind
    var size: CGFloat = 20

    var body: some View {
        let (top, bottom) = kind.colors
        Group {
            switch kind {
            case .image: imageIcon(top)
            case .folder: folderIcon(top, bottom)
            case .reply: replyIcon(top, bottom)
            default: sheetIcon(top, bottom)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: Лист

    private func sheetIcon(_ top: Color, _ bottom: Color) -> some View {
        ZStack {
            GlyphShape(path: Self.sheet)
                .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            GlyphShape(path: Self.fold).fill(.white.opacity(0.45))
            mark
        }
        .shadow(color: bottom.opacity(0.25), radius: size * 0.04, y: size * 0.03)
    }

    @ViewBuilder private var mark: some View {
        let line = StrokeStyle(lineWidth: max(1, size * 0.07), lineCap: .round, lineJoin: .round)
        switch kind {
        case .pdf:
            Text("PDF")
                .font(.system(size: size * 0.22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .offset(y: size * 0.12)
        case .sheet:
            GlyphShape(path: Self.grid).stroke(.white, style: StrokeStyle(lineWidth: max(0.9, size * 0.06)))
        case .slides:
            GlyphShape(path: Self.slide).stroke(.white, style: line)
        case .code:
            GlyphShape(path: Self.brackets).stroke(.white, style: line)
        case .mail:
            GlyphShape(path: Self.envelope).stroke(.white, style: StrokeStyle(lineWidth: max(0.9, size * 0.06), lineCap: .round, lineJoin: .round))
        default:
            // Три строки текста, последняя короче. Раньше средняя была «закрашена» — эхо старой иконки
            // с плашками; у знака теперь очки, а плашка обещала необратимость, которой в приложении нет.
            GlyphShape(path: Self.lines).stroke(.white.opacity(0.95), style: line)
        }
    }

    // MARK: Особые

    private func imageIcon(_ top: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(LinearGradient(colors: [top, Color(hex: 0xA9DDFF)], startPoint: .top, endPoint: .bottom))
                .padding(size * 0.1)
            GlyphShape(path: Self.hills).fill(LinearGradient(colors: [Color(hex: 0xFFD25A), Color(hex: 0xF29B2E)], startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).inset(by: size * 0.1))
            Circle().fill(.white).frame(width: size * 0.17, height: size * 0.17).offset(x: size * 0.15, y: -size * 0.14)
        }
    }

    private func folderIcon(_ top: Color, _ bottom: Color) -> some View {
        ZStack {
            GlyphShape(path: Self.folderBack).fill(bottom)
            GlyphShape(path: Self.folderFront).fill(LinearGradient(colors: [top, bottom.opacity(0.95)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func replyIcon(_ top: Color, _ bottom: Color) -> some View {
        ZStack {
            GlyphShape(path: Self.bubble).fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            Glyph(kind: .restore, size: size * 0.5, weight: max(1.1, size * 0.075)).foregroundStyle(.white).offset(y: -size * 0.03)
        }
    }

    // MARK: Пути (сетка 24×24)

    private static let sheet: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 7, y: 2.5)); p.addLine(to: CGPoint(x: 14.5, y: 2.5)); p.addLine(to: CGPoint(x: 19.5, y: 7.5))
        p.addLine(to: CGPoint(x: 19.5, y: 19)); p.addQuadCurve(to: CGPoint(x: 17, y: 21.5), control: CGPoint(x: 19.5, y: 21.5))
        p.addLine(to: CGPoint(x: 7, y: 21.5)); p.addQuadCurve(to: CGPoint(x: 4.5, y: 19), control: CGPoint(x: 4.5, y: 21.5))
        p.addLine(to: CGPoint(x: 4.5, y: 5)); p.addQuadCurve(to: CGPoint(x: 7, y: 2.5), control: CGPoint(x: 4.5, y: 2.5))
        p.closeSubpath()
        return p
    }()

    private static let fold: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 14.5, y: 2.5)); p.addLine(to: CGPoint(x: 14.5, y: 6)); p.addQuadCurve(to: CGPoint(x: 16, y: 7.5), control: CGPoint(x: 14.5, y: 7.5))
        p.addLine(to: CGPoint(x: 19.5, y: 7.5)); p.closeSubpath()
        return p
    }()

    private static let lines: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 8, y: 11)); p.addLine(to: CGPoint(x: 16, y: 11))
        p.move(to: CGPoint(x: 8, y: 14.25)); p.addLine(to: CGPoint(x: 16, y: 14.25))
        p.move(to: CGPoint(x: 8, y: 17.5)); p.addLine(to: CGPoint(x: 13.5, y: 17.5))
        return p
    }()

    private static let grid: Path = {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 7.8, y: 10.2, width: 8.4, height: 8), cornerSize: CGSize(width: 1, height: 1))
        p.move(to: CGPoint(x: 7.8, y: 14.2)); p.addLine(to: CGPoint(x: 16.2, y: 14.2))
        p.move(to: CGPoint(x: 12, y: 10.2)); p.addLine(to: CGPoint(x: 12, y: 18.2))
        return p
    }()

    private static let slide: Path = {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 7.8, y: 10.5, width: 8.4, height: 5.6), cornerSize: CGSize(width: 1, height: 1))
        p.move(to: CGPoint(x: 10, y: 18.6)); p.addLine(to: CGPoint(x: 14, y: 18.6))
        return p
    }()

    private static let brackets: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 10.2, y: 11.5)); p.addLine(to: CGPoint(x: 8, y: 14.2)); p.addLine(to: CGPoint(x: 10.2, y: 16.9))
        p.move(to: CGPoint(x: 13.8, y: 11.5)); p.addLine(to: CGPoint(x: 16, y: 14.2)); p.addLine(to: CGPoint(x: 13.8, y: 16.9))
        return p
    }()

    private static let envelope: Path = {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 7.6, y: 11, width: 8.8, height: 6.6), cornerSize: CGSize(width: 1, height: 1))
        p.move(to: CGPoint(x: 8, y: 11.6)); p.addLine(to: CGPoint(x: 12, y: 14.6)); p.addLine(to: CGPoint(x: 16, y: 11.6))
        return p
    }()

    private static let hills: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 2, y: 22)); p.addLine(to: CGPoint(x: 2, y: 17.5))
        p.addQuadCurve(to: CGPoint(x: 13, y: 15.5), control: CGPoint(x: 8, y: 11.5))
        p.addQuadCurve(to: CGPoint(x: 22, y: 15), control: CGPoint(x: 18, y: 12.5))
        p.addLine(to: CGPoint(x: 22, y: 22)); p.closeSubpath()
        return p
    }()

    static let folderBack: Path = {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 2.5, y: 4.5, width: 19, height: 15.5), cornerSize: CGSize(width: 2.4, height: 2.4))
        p.addRoundedRect(in: CGRect(x: 2.5, y: 3.5, width: 8.5, height: 4), cornerSize: CGSize(width: 1.6, height: 1.6))
        return p
    }()

    static let folderFront: Path = {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 2.5, y: 8, width: 19, height: 12.5), cornerSize: CGSize(width: 2.4, height: 2.4))
        return p
    }()

    private static let bubble: Path = {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 2.5, y: 3.5, width: 19, height: 14.5), cornerSize: CGSize(width: 5, height: 5), style: .continuous)
        p.move(to: CGPoint(x: 7, y: 17)); p.addLine(to: CGPoint(x: 6.2, y: 21.2)); p.addLine(to: CGPoint(x: 11.5, y: 17.5)); p.closeSubpath()
        return p
    }()
}
