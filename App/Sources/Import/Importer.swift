import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Кто читает файл: движок (сохраняя формат) или Swift (извлекает текст из PDF, сканов, картинок, RTF/DOC/ODT).
enum Importer {
    enum Route: Equatable {
        case engine
        case extract
        case unsupported(String)
    }

    static let extractable: Set<String> = ["pdf", "rtf", "rtfd", "doc", "odt", "wordml", "webarchive"]
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    static func route(for url: URL, engineExtensions: Set<String>) -> Route {
        let ext = url.pathExtension.lowercased()
        if engineExtensions.contains("." + ext) { return .engine }
        if extractable.contains(ext) || imageTypes.contains(ext) { return .extract }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) { return .extract }
        switch ext {
        case "pages", "numbers", "key":
            return .unsupported("Сохраните документ в DOCX, XLSX или PDF")
        case "xls":
            return .unsupported("Сохраните таблицу в XLSX")
        case "ppt":
            return .unsupported("Сохраните презентацию в PPTX")
        case "zip", "rar", "7z", "dmg", "app", "exe", "mp3", "mp4", "mov", "wav", "m4a":
            return .unsupported("Такой формат не поддерживается")
        default:
            return .engine  // движок сам проверит, текстовый ли это файл
        }
    }

    // MARK: Извлечение текста

    static func extractText(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await rawText(from: url, progress: progress).precomposedStringWithCanonicalMapping
    }

    private static func rawText(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return try await pdfText(url, progress: progress) }
        if imageTypes.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .image) == true {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ImportError.unreadable }
            let text = try await recognize(image)
            progress(1)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ImportError.noText }
            return text
        }
        return try await MainActor.run { try attributedText(url) }  // импорт HTML/DOC требует главного потока
    }

    @MainActor
    private static func attributedText(_ url: URL) throws -> String {
        let type: NSAttributedString.DocumentType? = switch url.pathExtension.lowercased() {
        case "rtf": .rtf
        case "rtfd": .rtfd
        case "doc": .docFormat
        case "odt": .openDocument
        case "wordml": .wordML
        case "webarchive": .webArchive
        default: nil
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if let type { options[.documentType] = type }
        let s = try NSAttributedString(url: url, options: options, documentAttributes: nil)
        return s.string
    }

    private static func pdfText(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ImportError.unreadable }
        if doc.isLocked { throw ImportError.locked }
        var pages: [String] = []
        let count = max(doc.pageCount, 1)
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 25,
               let image = render(page) {  // скан без текстового слоя → OCR
                text = try await recognize(image)
            }
            pages.append(text)
            progress(Double(i + 1) / Double(count))
        }
        let joined = pages.joined(separator: "\n\n")
        if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ImportError.noText }
        return joined
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.5
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Vision OCR. Русский поддерживается только в режиме .accurate.
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ru-RU", "en-US"]
            request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { throw ImportError.ocrFailed }
            let lines = (request.results ?? [])
                .sorted { a, b in
                    abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 ? a.boundingBox.midY > b.boundingBox.midY
                                                                         : a.boundingBox.minX < b.boundingBox.minX
                }
                .compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}

enum ImportError: LocalizedError {
    case unreadable, locked, noText, ocrFailed
    var errorDescription: String? {
        switch self {
        case .unreadable: "Файл не открывается"
        case .locked: "PDF защищён паролем"
        case .noText: "В файле нет текста"
        case .ocrFailed: "Не удалось распознать текст на изображении"
        }
    }
}
