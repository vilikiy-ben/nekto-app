import Foundation

enum EngineEvent: Sendable {
    case progress(Double)
    case result(JSONValue)
}

enum EngineError: LocalizedError, Equatable {
    case notInstalled
    case startFailed(String)
    case crashed
    case failed(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Модель ещё не установлена"
        case .startFailed(let m): "Модель не запустилась: \(m)"
        case .crashed: "Модель неожиданно завершила работу"
        case .failed(let code, let message):
            switch code {
            case "unsupported": "Такой формат не поддерживается"
            case "unreadable": "Файл не открывается: \(message)"
            case "cancelled": "Отменено"
            default: "Ошибка обработки (\(message))"
            }
        }
    }
}

/// Процесс-движок (Python) за песочницей без сети. Общение — JSON-строки через stdin/stdout.
actor EngineClient {
    static let shared = EngineClient()

    private var process: Process?
    private var input: FileHandle?
    private var waiters: [String: AsyncThrowingStream<EngineEvent, Error>.Continuation] = [:]
    private var hello: CheckedContinuation<Void, Error>?
    private var starting: Task<Void, Error>?

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: Жизненный цикл

    func start() async throws {
        if isRunning { return }
        if let starting { return try await starting.value }
        let task = Task { try await self.launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    func stop() {
        try? input?.close()
        process?.terminate()
        process = nil
    }

    private func launch() async throws {
        guard FileManager.default.isExecutableFile(atPath: AppPaths.venvPython.path) else { throw EngineError.notInstalled }
        try AppPaths.ensure(AppPaths.logs)
        let threads = min(4, ProcessInfo.processInfo.activeProcessorCount)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-f", AppPaths.sandboxProfile.path, AppPaths.venvPython.path, "-E", "-s",
                       AppPaths.bundleEngine.appendingPathComponent("run_engine.py").path,
                       "--model-dir", AppPaths.model.path, "--threads", "\(threads)"]
        p.environment = [
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "TOKENIZERS_PARALLELISM": "false",
            "OMP_NUM_THREADS": "\(threads)",
            "PATH": "/bin",  // без /usr/bin: там заглушки, открывающие диалог инструментов разработчика
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(), "LANG": "ru_RU.UTF-8", "PYTHONIOENCODING": "utf-8",
        ]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = Self.logHandle()

        let (lines, sink) = AsyncStream<Data>.makeStream()
        let splitter = LineSplitter(sink: sink)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                sink.finish()
            } else {
                splitter.feed(chunk)
            }
        }
        p.terminationHandler = { [weak self] _ in
            Task { await self?.didTerminate() }
        }
        do { try p.run() } catch { throw EngineError.startFailed(error.localizedDescription) }
        process = p
        input = stdin.fileHandleForWriting
        Task { [weak self] in
            for await line in lines { await self?.handle(line) }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.waitHello() }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw EngineError.startFailed("нет ответа")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func waitHello() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.hello = c
        }
    }

    private func didTerminate() {
        process = nil
        input = nil
        hello?.resume(throwing: EngineError.crashed)
        hello = nil
        for (_, w) in waiters { w.finish(throwing: EngineError.crashed) }
        waiters.removeAll()
    }

    // MARK: Запросы

    func request(_ op: String, _ params: [String: JSONValue] = [:]) async throws -> AsyncThrowingStream<EngineEvent, Error> {
        try await start()
        let id = UUID().uuidString
        var payload = params
        payload["id"] = .string(id)
        payload["op"] = .string(op)
        var data = try JSONEncoder().encode(JSONValue.object(payload))
        data.append(0x0A)
        let (stream, continuation) = AsyncThrowingStream<EngineEvent, Error>.makeStream()
        waiters[id] = continuation
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { Task { await self?.cancel(id) } }
        }
        do { try input?.write(contentsOf: data) } catch {
            waiters[id] = nil
            throw EngineError.crashed
        }
        return stream
    }

    /// Запрос с ожиданием результата; прогресс — в колбэк.
    func call(_ op: String, _ params: [String: JSONValue] = [:],
              progress: (@Sendable (Double) -> Void)? = nil) async throws -> JSONValue {
        for try await event in try await request(op, params) {
            switch event {
            case .progress(let v): progress?(v)
            case .result(let r): return r
            }
        }
        throw EngineError.crashed
    }

    func cancel(_ id: String) {
        guard let input, waiters[id] != nil else { return }
        var data = (try? JSONEncoder().encode(JSONValue.object(["op": "cancel", "target": .string(id)]))) ?? Data()
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    private func handle(_ line: Data) {
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: line) else { return }
        let event = msg["event"]?.string
        if event == "hello" {
            hello?.resume(); hello = nil
            return
        }
        guard let id = msg["id"]?.string, let waiter = waiters[id] else { return }
        switch event {
        case "progress":
            waiter.yield(.progress(msg["value"]?.double ?? 0))
        case "result":
            waiter.yield(.result(msg))
            waiter.finish()
            waiters[id] = nil
        case "error":
            waiter.finish(throwing: EngineError.failed(code: msg["code"]?.string ?? "internal",
                                                       message: msg["message"]?.string ?? ""))
            waiters[id] = nil
        default:
            break
        }
    }

    private static func logHandle() -> FileHandle {
        let url = AppPaths.logs.appendingPathComponent("engine.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return FileHandle.nullDevice }
        _ = try? h.seekToEnd()
        return h
    }
}

/// Режет поток байтов на строки (JSON-строки движка).
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let sink: AsyncStream<Data>.Continuation

    init(sink: AsyncStream<Data>.Continuation) { self.sink = sink }

    /// Сколько начала буфера уже просмотрено без перевода строки: ответ с большим видом документа — мегабайты
    /// одной строкой, и искать перевод строки каждый раз с начала значило бы квадратичное время.
    private var scanned = 0

    func feed(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        var start = buffer.startIndex
        var from = buffer.startIndex + scanned
        while let nl = buffer[from...].firstIndex(of: 0x0A) {
            let line = buffer[start..<nl]
            if !line.isEmpty { sink.yield(Data(line)) }
            start = nl + 1
            from = start
        }
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        scanned = buffer.count
    }
}
