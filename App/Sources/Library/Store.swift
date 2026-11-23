import AppKit
import Foundation

/// История обработок на диске — внутри рабочей папки, рядом с результатами.
///
/// ```
/// Рабочая папка/
///   2026-11-21 Трудовой договор [ФИО_1]/      ← результаты: их пользователь открывает и отправляет
///     Трудовой договор [ФИО_1] (обезличено).docx
///     Ответ нейросети (с данными).txt
///   .nekto/                                    ← скрытая служебная папка
///     README.txt
///     <id обработки>/
///       processing.json                        ← заголовок, документы, режимы, таблица меток
///       items/<id>/source/<исходный файл>      ← копия входа для пересчёта после правок
///       items/<id>/text.txt                    ← вставленный текст или распознанный скан
///       items/<id>/preview.txt                 ← что копируется в чат (обезличенный текст или Markdown)
///       items/<id>/layout.json                 ← вид документа в ленте и редакторе (`DocumentLayout`)
/// ```
/// Таблица меток содержит исходные данные, поэтому лежит не рядом с результатами, а в `.nekto`: с обезличенными
/// файлами она в чат не уйдёт. Восстановленный ответ («… (с данными).txt») — исключение: он в папке результатов,
/// и отправлять папку в чат целиком нельзя.
@MainActor
enum Store {
    static let folderName = Brand.historyFolder

    static func dataRoot(_ root: URL) -> URL { root.appendingPathComponent(folderName, isDirectory: true) }

    static func itemDir(_ job: Job, in processing: Processing) -> URL {
        processing.dataDir.appendingPathComponent("items/\(job.id.uuidString)", isDirectory: true)
    }

    // MARK: Чтение

    /// Все обработки папки, новые сверху. Тексты не читаются — только то, что нужно боковой панели.
    static func loadAll(root: URL) -> [Processing] {
        let base = dataRoot(root)
        guard let ids = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [Processing] = []
        for dir in ids where dir.hasDirectoryPath {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("processing.json")),
                  let record = try? decoder.decode(ProcessingRecord.self, from: data) else { continue }
            out.append(record.makeProcessing(root: root))
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Дочитывает тексты ленты: обезличенные предпросмотры и вставленные тексты.
    static func hydrate(_ p: Processing) {
        guard !p.hydrated else { return }
        for job in p.items {
            let dir = itemDir(job, in: p)
            if job.kind != .file {
                job.inputText = try? String(contentsOf: dir.appendingPathComponent("text.txt"), encoding: .utf8)
            }
            if var out = job.output {
                // Предпросмотр из .nekto; у старых ответов нейросети его нет — читаем сам файл результата.
                let preview = try? String(contentsOf: dir.appendingPathComponent("preview.txt"), encoding: .utf8)
                out.text = preview ?? out.fileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? out.text
                out.layout = readLayout(dir) ?? legacyLayout(job, text: out.text, mapping: p.mapping)
                if !job.isReply { out.tagCounts = Restorer.tagCounts(in: out.document.text) }
                job.output = out
            }
        }
        p.hydrated = true
    }

    // MARK: Запись

    static func save(_ p: Processing) {
        guard !p.isDeleted else { return }
        let record = ProcessingRecord(p)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: p.dataDir, withIntermediateDirectories: true)
            ensureReadme(root: p.root)
            try encoder.encode(record).write(to: p.dataDir.appendingPathComponent("processing.json"), options: .atomic)
        } catch {
            NSLog("\(Brand.name): не удалось сохранить обработку: \(error.localizedDescription)")
        }
    }

    static func savePreview(_ output: JobOutput, for job: Job, in p: Processing) {
        guard !p.isDeleted else { return }
        let dir = itemDir(job, in: p)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? output.text.write(to: dir.appendingPathComponent("preview.txt"), atomically: true, encoding: .utf8)
        let layoutURL = dir.appendingPathComponent("layout.json")
        if let layout = output.layout, let data = try? JSONEncoder().encode(layout.json) {
            try? data.write(to: layoutURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: layoutURL)
        }
    }

    private static func readLayout(_ dir: URL) -> DocumentLayout? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("layout.json")) else { return nil }
        return DocumentLayout(json: try? JSONDecoder().decode(JSONValue.self, from: data))
    }

    /// История до вида документа: ответ нейросети раскладывается из его Markdown, таблица Excel — тоже
    /// (её предпросмотр и раньше был Markdown-таблицей). Остальное — текстом, как было.
    private static func legacyLayout(_ job: Job, text: String, mapping: [MappingEntry]) -> DocumentLayout? {
        if job.isReply, let input = job.inputText { return MarkdownLayout.reply(input, mapping: mapping) }
        if job.fileKind == .sheet, text.hasPrefix("### ") { return MarkdownLayout.parse(text) }
        return nil
    }

    static func saveInputText(_ text: String, for job: Job, in p: Processing) throws -> URL {
        let dir = itemDir(job, in: p)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("text.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Копия исходного файла: пользователь может удалить его из «Загрузок», а исправить пропуск модели
    /// захочет и через неделю. Имя сохраняем — по нему движок называет результат.
    static func copySource(_ url: URL, for job: Job, in p: Processing) throws -> URL {
        let dir = itemDir(job, in: p).appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.copyItem(at: url, to: dst)
        return dst
    }

    static func ensureReadme(root: URL) {
        let url = dataRoot(root).appendingPathComponent("README.txt")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        Служебная папка \(Brand.name).

        Здесь история обработок этой рабочей папки: копии исходных документов и таблицы меток \
        (какая метка какие данные заменяет). Без неё нельзя вернуть данные в ответ нейросети \
        и исправить ошибку модели в старой обработке.

        В этой папке лежат исходные персональные данные. Не отправляйте её в чат и не публикуйте.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Папка результатов

    /// Создаёт папку результатов обработки: «2026-11-21 Название». Имя не повторяется.
    static func ensureOutputFolder(for p: Processing) throws -> URL {
        if p.isDeleted { throw CancellationError() }
        if let existing = p.outputFolder, FileManager.default.fileExists(atPath: existing.path) { return existing }
        let date = p.createdAt.formatted(.iso8601.year().month().day())
        let base = sanitize("\(date) \(p.title)")
        let url = unique(base, in: p.root)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        p.folderName = url.lastPathComponent
        return url
    }

    /// Переименование обработки переименовывает и её папку (если имя свободно).
    static func renameOutputFolder(of p: Processing) {
        guard let old = p.outputFolder, FileManager.default.fileExists(atPath: old.path) else { return }
        let date = p.createdAt.formatted(.iso8601.year().month().day())
        let wanted = sanitize("\(date) \(p.title)")
        guard wanted != old.lastPathComponent else { return }
        let target = unique(wanted, in: p.root)
        do {
            try FileManager.default.moveItem(at: old, to: target)
            p.folderName = target.lastPathComponent
            for job in p.items {
                if var out = job.output, let file = out.fileURL, file.deletingLastPathComponent() == old {
                    out.fileURL = target.appendingPathComponent(file.lastPathComponent)
                    job.output = out
                }
            }
        } catch {
            NSLog("\(Brand.name): папку обработки не переименовать: \(error.localizedDescription)")
        }
    }

    /// Кладёт файл результата в папку обработки. Пересчёт того же документа заменяет прежний файл.
    static func place(_ file: URL, named name: String, replacing previous: URL?, in folder: URL) throws -> URL {
        let fm = FileManager.default
        if let previous, fm.fileExists(atPath: previous.path), previous.deletingLastPathComponent() == folder {
            try fm.removeItem(at: previous)
        }
        let dst = uniqueFile(name, in: folder)
        try fm.moveItem(at: file, to: dst)
        return dst
    }

    /// Удаление обработки — в Корзину (можно передумать): служебные данные всегда, папка с результатами —
    /// если человек так решил в диалоге удаления (`DeleteConfirmation`).
    static func trash(_ p: Processing, includingResults: Bool) {
        let fm = FileManager.default
        if includingResults, let folder = p.outputFolder, fm.fileExists(atPath: folder.path) {
            try? fm.trashItem(at: folder, resultingItemURL: nil)
        }
        if fm.fileExists(atPath: p.dataDir.path) { try? fm.trashItem(at: p.dataDir, resultingItemURL: nil) }
    }

    // MARK: Имена

    static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "–").replacingOccurrences(of: ":", with: "–")
        s = s.components(separatedBy: .newlines).joined(separator: " ")
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 90 { s = String(s.prefix(90)).trimmingCharacters(in: .whitespaces) + "…" }
        return s.trimmingCharacters(in: .whitespaces).isEmpty ? "Обработка" : s.trimmingCharacters(in: .whitespaces)
    }

    private static func unique(_ base: String, in dir: URL) -> URL {
        var url = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return url
    }

    private static func uniqueFile(_ name: String, in dir: URL) -> URL {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

// MARK: - Формат processing.json

private struct ProcessingRecord: Codable {
    var version = 1
    var id: UUID
    var title: String
    var customTitle: Bool
    var createdAt: Date
    var updatedAt: Date
    var folderName: String?
    var modes: [ProcessingMode]
    var items: [ItemRecord]
    var mapping: [JSONValue]
    var engineState: JSONValue?

    @MainActor
    init(_ p: Processing) {
        id = p.id
        title = p.title
        customTitle = p.customTitle
        createdAt = p.createdAt
        updatedAt = p.updatedAt
        folderName = p.folderName
        modes = p.modes.sorted { $0.rawValue < $1.rawValue }
        items = p.items.map { ItemRecord($0, root: p.root, data: p.dataDir) }
        mapping = p.mapping.map(\.json)
        engineState = p.engineState
    }

    @MainActor
    func makeProcessing(root: URL) -> Processing {
        let p = Processing(id: id, root: root, title: title, createdAt: createdAt)
        p.customTitle = customTitle
        p.updatedAt = updatedAt
        p.folderName = folderName
        p.modes = Set(modes)
        p.mapping = mapping.compactMap(MappingEntry.init)
        p.engineState = engineState
        p.items = items.map { $0.makeJob(in: p) }
        p.hydrated = false
        return p
    }
}

private struct ItemRecord: Codable {
    var id: UUID
    var kind: Job.Kind
    var name: String
    var number: Int
    var createdAt: Date
    var source: String?           // относительно папки обработки в .nekto
    var sourceIsExtractedText: Bool
    var output: String?           // относительно рабочей папки
    var replaced: Int
    var notes: [String]
    var restored: [[Int]]
    var unknownTags: [String]
    var error: String?
    /// Результат посчитан со старыми решениями, а пересчёт не успел закончиться (приложение закрылось).
    /// Без этой пометки документ считался бы готовым: в таблице меток значение «скрыто», а в файле — открыто.
    var stale: Bool?

    @MainActor
    init(_ job: Job, root: URL, data: URL) {
        id = job.id
        kind = job.kind
        name = job.name
        number = job.number
        createdAt = job.createdAt
        source = job.source.map { relative($0, to: data) }
        sourceIsExtractedText = job.sourceIsExtractedText
        output = job.output?.fileURL.map { relative($0, to: root) }
        replaced = job.output?.replaced ?? 0
        notes = job.output?.notes ?? []
        restored = job.output?.restored.map { [$0.location, $0.length] } ?? []
        unknownTags = job.output?.unknownTags ?? []
        if case .failed(let message) = job.state { error = message }
        stale = job.output != nil && (job.state.isActive || job.needsRerun) ? true : nil
    }

    @MainActor
    func makeJob(in p: Processing) -> Job {
        let job = Job(id: id, processing: p, kind: kind, name: name, number: number, createdAt: createdAt)
        job.source = source.map { p.dataDir.appendingPathComponent($0) }
        job.sourceIsExtractedText = sourceIsExtractedText
        if let error {
            job.state = .failed(error)
        } else {
            job.state = .done
            job.staleOutput = stale == true
            job.output = JobOutput(fileURL: output.map { p.root.appendingPathComponent($0) }, text: "", replaced: replaced,
                                   notes: notes, tagCounts: [],
                                   restored: restored.compactMap { $0.count == 2 ? NSRange(location: $0[0], length: $0[1]) : nil },
                                   unknownTags: unknownTags)
        }
        return job
    }
}

nonisolated private func relative(_ url: URL, to base: URL) -> String {
    let path = url.standardizedFileURL.path
    let prefix = base.standardizedFileURL.path + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
}
