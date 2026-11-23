import AppKit
import Foundation

/// Конвейер: отправка из строки ввода → очередь → движок → файл в папке обработки.
///
/// Задания выполняются строго по одному: движок однопоточный. Каждая обработка — своя сессия
/// движка (свои метки). После перезапуска сессия поднимается из сохранённого состояния
/// (`restore`), поэтому старую обработку можно продолжить: добавить документ, исправить ошибку модели,
/// вставить ответ нейросети.
extension AppModel {

    // MARK: Отправка

    func send() {
        guard composer.canSend, let root = folders.current else { return }
        // Файлы и текст не уходят вместе: пока есть файлы, отправляются только они.
        let files = composer.attachments.flatMap(expand)
        let text = composer.hasFiles ? "" : TextRepair.fix(composer.trimmedText).precomposedStringWithCanonicalMapping
        guard !files.isEmpty || !text.isEmpty else { composer.clearAttachments(); return }

        let p: Processing
        if let existing = current {
            p = existing
        } else {
            p = Processing(root: root)
            p.modes = composer.modes
            insertIntoHistory(p)
            go(.processing(p.id))
        }
        if case .reader = place { go(.processing(p.id)) }

        for url in files {
            let job = Job(processing: p, kind: .file, name: url.lastPathComponent, number: p.nextNumber(for: .file))
            job.origin = url
            enqueue(job, in: p)
        }
        if !text.isEmpty {
            let kind: Job.Kind = looksLikeReply(text, in: p) ? .reply : .text
            let number = p.nextNumber(for: kind)
            let name = kind == .reply ? (number > 1 ? "Ответ нейросети \(number)" : "Ответ нейросети")
                                      : (number > 1 ? "Текст \(number)" : "Текст")
            let job = Job(processing: p, kind: kind, name: name, number: number)
            job.inputText = text
            do { job.source = try Store.saveInputText(text, for: job, in: p) } catch {
                job.state = .failed("Не удалось сохранить текст в рабочую папку")
            }
            enqueue(job, in: p)
            composer.text = ""
        } else {
            composer.clearAttachments()
        }
        touch(p)
        Store.save(p)
        pump()
    }

    /// В тексте есть метки этой обработки — значит, это ответ нейросети, и данные надо вернуть.
    func looksLikeReply(_ text: String, in p: Processing) -> Bool {
        !p.mapping.isEmpty && !Restorer.restore(text, mapping: p.mapping).restored.isEmpty
    }

    private func enqueue(_ job: Job, in p: Processing) {
        p.items.append(job)
        if case .failed = job.state { return }
        job.state = .queued
        queue.append(job)
        live[p.id] = p
    }

    /// Документы, которые закрытие приложения застало посреди пересчёта после правки: их файлы и тексты — со старыми
    /// решениями. Пересчитываем сразу, не дожидаясь, пока обработку откроют: файл в папке результатов могут унести
    /// из Finder, не открывая приложения. Пока идёт пересчёт, виден прежний результат с «Обновляю файл…».
    func resumeStale(_ p: Processing) {
        let stale = p.items.filter { $0.staleOutput && !$0.state.isActive }
        guard !stale.isEmpty else { return }
        for job in stale {
            job.staleOutput = false
            job.state = .queued
            if !queue.contains(where: { $0 === job }) { queue.append(job) }
        }
        live[p.id] = p
        pump()
    }

    func retry(_ job: Job) {
        guard let p = job.processing else { return }
        job.state = .queued
        if !queue.contains(where: { $0 === job }) { queue.append(job) }
        live[p.id] = p
        pump()
    }

    /// Папки раскрываем в файлы (без скрытых и без вложенных пакетов).
    private func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [url] }
        let it = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var out: [URL] = []
        while let f = it?.nextObject() as? URL, out.count < 200 {
            if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(f) }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Движок

    func warmEngine() {
        guard engine != .ready, engine != .warming else { return }
        engine = .warming
        Task {
            do {
                let res = try await EngineClient.shared.call("load")
                engineExtensions = Set(res["extensions"]?.array.compactMap(\.string) ?? [])
                engine = .ready
                pump()
            } catch {
                engine = .failed((error as? LocalizedError)?.errorDescription ?? "Ошибка")
            }
        }
    }

    /// Сессия движка для обработки: поднять сохранённое состояние и режимы.
    func ensureSession(_ p: Processing) async throws {
        guard !loadedSessions.contains(p.id) else { return }
        if let state = p.engineState {
            _ = try await EngineClient.shared.call("restore", ["session": .string(p.id.uuidString), "state": state])
        }
        let res = try await EngineClient.shared.call("configure",
            ["session": .string(p.id.uuidString)].merging(ProcessingMode.engineConfig(p.modes)) { a, _ in a })
        absorb(res, into: p)
        p.edits.engineModes = p.modes
        loadedSessions.insert(p.id)
    }

    func absorb(_ res: JSONValue, into p: Processing) {
        if let mapping = res["mapping"] { p.mapping = mapping.array.compactMap(MappingEntry.init) }
        if let state = res["state"] { p.engineState = state }
    }

    // MARK: Очередь

    func pump() {
        guard !pumping, phase == .ready else { return }
        // Ответ нейросети модели не нужен; документы ждут, пока она загрузится.
        let engineUp = engine == .ready || engine == .warming
        guard let job = queue.first(where: { j in
            guard case .queued = j.state else { return false }
            return engineUp || j.isReply
        }) else {
            queue.removeAll { !$0.state.isActive }
            return
        }
        pumping = true
        job.task = Task {
            await run(job)
            queue.removeAll { $0 === job }
            // Пока документ считался, пришла новая правка: результат уже устарел, считаем ещё раз, первым.
            if job.needsRerun, job.output != nil {
                job.needsRerun = false
                job.state = .queued
                queue.insert(job, at: 0)
            }
            pumping = false
            if let p = job.processing {
                Store.save(p)
                if !p.isBusy { live[p.id] = nil }
            }
            pump()
        }
    }

    private func run(_ job: Job) async {
        guard let p = job.processing else { return }
        do {
            let output: JobOutput
            switch job.kind {
            case .reply:
                output = try restoreReply(job, in: p)
            case .text:
                job.state = .cleaning(0)
                try await ensureSession(p)
                let text = try job.inputText ?? String(contentsOf: job.source!, encoding: .utf8)
                output = try await cleanText(text, name: job.name, job: job, in: p)
            case .file:
                output = try await cleanFile(job, in: p)
            }
            try Task.checkCancellation()
            job.output = output
            job.state = .done
            Store.savePreview(output, for: job, in: p)
        } catch is CancellationError {
            job.state = .failed("Отменено")
        } catch {
            job.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            if (error as? EngineError) == .crashed {
                loadedSessions.removeAll()
                engine = .idle
                warmEngine()
            }
        }
    }

    private func cleanFile(_ job: Job, in p: Processing) async throws -> JobOutput {
        // Первый запуск: решаем, кто читает файл, и кладём копию входа в .nekto.
        if job.source == nil {
            guard let origin = job.origin else { throw PipelineError.sourceMissing }
            switch Importer.route(for: origin, engineExtensions: engineExtensions) {
            case .unsupported(let message):
                throw PipelineError.message(message)
            case .extract:
                job.state = .reading(0)
                let text = try await Importer.extractText(from: origin) { value in
                    Task { @MainActor in if case .reading = job.state { job.state = .reading(value) } }
                }
                job.source = try Store.saveInputText(text, for: job, in: p)
                job.sourceIsExtractedText = true
            case .engine:
                job.source = try Store.copySource(origin, for: job, in: p)
            }
        }
        guard let source = job.source, FileManager.default.fileExists(atPath: source.path) else { throw PipelineError.sourceMissing }

        job.state = .cleaning(0)
        try await ensureSession(p)
        if job.sourceIsExtractedText {
            let text = try String(contentsOf: source, encoding: .utf8)
            return try await cleanText(text, name: (job.name as NSString).deletingPathExtension, job: job, in: p)
        }
        let staging = try stagingDir(for: job, in: p)
        defer { try? FileManager.default.removeItem(at: staging) }
        let res = try await EngineClient.shared.call("clean_file", [
            "session": .string(p.id.uuidString), "path": .string(source.path), "out_dir": .string(staging.path),
        ]) { value in Task { @MainActor in job.state = .cleaning(value) } }
        absorb(res, into: p)
        let preview = res["preview"]?.string ?? ""
        let layout = DocumentLayout(json: res["layout"])
        var fileURL: URL?
        if let produced = res["output"]?.string.map({ URL(fileURLWithPath: $0) }) {
            adoptTitle(from: produced.deletingPathExtension().lastPathComponent, in: p)
            let folder = try Store.ensureOutputFolder(for: p)
            fileURL = try Store.place(produced, named: produced.lastPathComponent, replacing: job.output?.fileURL, in: folder)
        }
        return JobOutput(fileURL: fileURL, text: preview, layout: layout, replaced: res["replaced"]?.int ?? 0,
                         notes: res["notes"]?.array.compactMap(\.string) ?? [], tagCounts: Restorer.tagCounts(in: layout?.text ?? preview))
    }

    private func cleanText(_ text: String, name: String, job: Job, in p: Processing) async throws -> JobOutput {
        let res = try await EngineClient.shared.call("clean_text", [
            "session": .string(p.id.uuidString), "text": .string(text), "name": .string(name),
        ]) { value in Task { @MainActor in job.state = .cleaning(value) } }
        absorb(res, into: p)
        let cleaned = res["text"]?.string ?? ""
        let safeName = res["name"]?.string ?? name
        if job.kind == .text { adoptTitle(fromText: cleaned, in: p) } else { adoptTitle(from: safeName, in: p) }

        let staging = try stagingDir(for: job, in: p)
        defer { try? FileManager.default.removeItem(at: staging) }
        let draft = staging.appendingPathComponent("\(safeName) (обезличено).txt")
        try cleaned.write(to: draft, atomically: true, encoding: .utf8)
        let folder = try Store.ensureOutputFolder(for: p)
        let file = try Store.place(draft, named: draft.lastPathComponent, replacing: job.output?.fileURL, in: folder)
        return JobOutput(fileURL: file, text: cleaned, layout: DocumentLayout(json: res["layout"]), replaced: res["replaced"]?.int ?? 0,
                         notes: [], tagCounts: Restorer.tagCounts(in: cleaned))
    }

    private func restoreReply(_ job: Job, in p: Processing) throws -> JobOutput {
        let text = try job.inputText ?? String(contentsOf: job.source!, encoding: .utf8)
        let result = Restorer.restore(text, mapping: p.mapping)
        let folder = try Store.ensureOutputFolder(for: p)
        let staging = try stagingDir(for: job, in: p)
        defer { try? FileManager.default.removeItem(at: staging) }
        let draft = staging.appendingPathComponent("\(job.name) (с данными).txt")
        try result.text.write(to: draft, atomically: true, encoding: .utf8)
        let file = try Store.place(draft, named: draft.lastPathComponent, replacing: job.output?.fileURL, in: folder)
        return JobOutput(fileURL: file, text: result.text, layout: MarkdownLayout.reply(text, mapping: p.mapping),
                         replaced: result.restored.count, notes: [], tagCounts: [],
                         restored: result.restored, unknownTags: Array(Set(result.unknown)).sorted())
    }

    private func stagingDir(for job: Job, in p: Processing) throws -> URL {
        let dir = p.dataDir.appendingPathComponent("staging/\(job.id.uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Заголовок

    /// Заголовок — из обезличенного результата: в истории не должно быть имён и телефонов.
    private func adoptTitle(from cleanedName: String, in p: Processing) {
        guard !p.customTitle, p.folderName == nil else { return }
        let name = cleanedName.replacingOccurrences(of: " (обезличено)", with: "")
        p.title = Self.shorten(name)
    }

    private func adoptTitle(fromText cleaned: String, in p: Processing) {
        guard !p.customTitle, p.folderName == nil else { return }
        let line = cleaned.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.count >= 3 } ?? "Текст"
        p.title = Self.shorten(line.replacingOccurrences(of: #"^[#>*\-\s]+"#, with: "", options: .regularExpression))
    }

    static func shorten(_ s: String, limit: Int = 56) -> String {
        let collapsed = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

enum PipelineError: LocalizedError {
    case sourceMissing
    case message(String)
    var errorDescription: String? {
        switch self {
        case .sourceMissing: "Исходный файл не найден"
        case .message(let m): m
        }
    }
}
