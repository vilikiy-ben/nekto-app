import Foundation
import Observation

/// Первая установка: Python-окружение и модель качаются параллельно, затем самопроверка.
@MainActor
@Observable
final class Installer {
    enum Step: Int, CaseIterable, Identifiable, Sendable {
        case runtime, model, check
        var id: Int { rawValue }
        /// Как шаг называется в онбординге (шаги 3а и 3б).
        var title: String {
            switch self {
            case .runtime: "Компоненты для запуска"
            case .model: "Модель"
            case .check: "Пробный запуск"
            }
        }
        var weight: Double {
            switch self {
            case .runtime: 0.17   // ~60 МБ пакетов из PyPI
            case .model: 0.71     // 0,7 ГБ модели
            case .check: 0.12     // первый запуск раскладывает веса модели для отображения в память
            }
        }
    }

    enum Status: Equatable { case pending, running, done, failed }

    private(set) var status: [Step: Status] = [.runtime: .pending, .model: .pending, .check: .pending]
    private(set) var progress: [Step: Double] = [.runtime: 0, .model: 0, .check: 0]
    private(set) var detail: [Step: String] = [:]
    private(set) var errorMessage: String?
    private(set) var isRunning = false

    var overall: Double { Step.allCases.reduce(0) { $0 + $1.weight * (progress[$1] ?? 0) } }
    var isDone: Bool { Step.allCases.allSatisfy { status[$0] == .done } }

    // MARK: Состояние установки

    struct State: Codable { var lock: String; var model: String; var python: String }

    nonisolated static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: AppPaths.state),
              let state = try? JSONDecoder().decode(State.self, from: data),
              state.lock == Manifest.lockDigest, state.model == Manifest.modelRevision,
              FileManager.default.isExecutableFile(atPath: AppPaths.venvPython.path) else { return false }
        return Manifest.modelFiles.allSatisfy { f in
            let url = AppPaths.model.appendingPathComponent(f.path)
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) == f.size
        }
    }

    nonisolated static var hasEverStarted: Bool { FileManager.default.fileExists(atPath: AppPaths.support.path) }

    // MARK: Запуск

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        for step in Step.allCases where status[step] == .failed { status[step] = .pending; progress[step] = 0 }

        do {
            try checkDiskSpace()
            // Шаги по очереди: параллельно модель забирала почти весь канал, и «Среда» стояла на месте.
            if status[.runtime] != .done { try await installRuntime() }
            if status[.model] != .done { try await downloadModel() }
            try await selfCheck()
            try writeState()
            try? FileManager.default.removeItem(at: AppPaths.uvCache)
            try? FileManager.default.removeItem(at: AppPaths.downloads)
            removeOtherModels()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            for step in Step.allCases where status[step] == .running { status[step] = .failed }
        }
    }

    private func set(_ step: Step, _ s: Status) { status[step] = s }
    private func report(_ step: Step, _ value: Double, _ text: String? = nil) {
        progress[step] = max(progress[step] ?? 0, min(value, 1))
        if let text { detail[step] = text }
    }

    private func checkDiskSpace() throws {
        try AppPaths.ensure(AppPaths.support)
        let values = try AppPaths.support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values.volumeAvailableCapacityForImportantUsage, free < Manifest.requiredFreeBytes {
            throw SetupError.diskSpace(needed: Manifest.requiredFreeBytes)
        }
    }

    // MARK: Python-окружение (uv)

    private func installRuntime() async throws {
        set(.runtime, .running)
        report(.runtime, 0.01, "Python")
        try AppPaths.ensure(AppPaths.runtime)
        try AppPaths.ensure(AppPaths.uvCache)

        let poll = Task { [weak self] in
            while !Task.isCancelled {
                let sizes = await Task.detached(priority: .utility) {
                    (Hashing.directorySize(AppPaths.pythonInstall), Hashing.directorySize(AppPaths.uvCache),
                     Hashing.directorySize(AppPaths.venv))
                }.value
                let p = 0.08 * min(1, Double(sizes.0) / Double(Manifest.pythonBytes))
                    + 0.55 * min(1, Double(sizes.1) / Double(Manifest.downloadBytes))
                    + 0.35 * min(1, Double(sizes.2) / Double(Manifest.venvBytes))
                self?.report(.runtime, p)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { poll.cancel() }

        let uv = Toolchain()
        try await uv.run(["python", "install", Manifest.pythonVersion, "--no-bin"])
        report(.runtime, 0.08, "Пакеты")
        try await uv.run(["venv", AppPaths.venv.path, "--python", Manifest.pythonVersion, "--clear"])
        let lock = AppPaths.bundleEngine.appendingPathComponent("requirements.lock").path
        try await uv.run(["pip", "sync", lock, "--require-hashes", "--python", AppPaths.venvPython.path])
        poll.cancel()
        report(.runtime, 1, "")
        set(.runtime, .done)
    }

    // MARK: Модель

    private func downloadModel() async throws {
        set(.model, .running)
        try AppPaths.ensure(AppPaths.model)
        try AppPaths.ensure(AppPaths.downloads)
        let total = Manifest.modelBytes
        var finished: Int64 = 0

        for file in Manifest.modelFiles {
            let target = AppPaths.model.appendingPathComponent(file.path)
            if Self.verified(target, file) {
                finished += file.size
                report(.model, Double(finished) / Double(total))
                continue
            }
            let base = finished
            let tmp = try await Downloader.fetch(file.url, expectedSize: file.size) { [weak self] got in
                Task { @MainActor in
                    let done = base + got
                    self?.report(.model, 0.97 * Double(done) / Double(total),
                                 "\(RU.megabytes(done)) из \(RU.megabytes(total))")
                }
            }
            if file.size > 50_000_000 { report(.model, 0.97 * Double(base + file.size) / Double(total), "Проверяю файл") }
            let digest = try await Task.detached(priority: .userInitiated) { try Hashing.sha256Hex(fileAt: tmp) }.value
            guard digest == file.sha256 else {
                try? FileManager.default.removeItem(at: tmp)
                throw SetupError.checksum(file.path)
            }
            try AppPaths.ensure(target.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tmp, to: target)
            finished += file.size
        }
        report(.model, 1, RU.megabytes(total))
        set(.model, .done)
    }

    nonisolated static func verified(_ url: URL, _ file: Manifest.ModelFile) -> Bool {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) == file.size else { return false }
        if file.size > 50_000_000 { return true }  // крупный файл сверяли при загрузке; повторно — дорого
        return (try? Hashing.sha256Hex(fileAt: url)) == file.sha256
    }

    // MARK: Самопроверка

    private func selfCheck() async throws {
        set(.check, .running)
        report(.check, 0.15, "Запускаю модель")
        await EngineClient.shared.stop()
        _ = try await EngineClient.shared.call("load")
        report(.check, 0.75, "Пробный текст")
        let res = try await EngineClient.shared.call("selftest")
        guard res["ok"]?.bool == true else { throw SetupError.selftest }
        report(.check, 1, "")
        set(.check, .done)
    }

    /// Модели прежних версий приложения (например, gliner2 на 1,1 ГБ) больше не нужны — освобождаем место.
    /// Только после успешной самопроверки новой модели и только папки рядом с ней.
    private func removeOtherModels() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: AppPaths.models, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent != Manifest.modelFolder {
            try? fm.removeItem(at: item)
        }
    }

    private func writeState() throws {
        let state = State(lock: Manifest.lockDigest, model: Manifest.modelRevision, python: Manifest.pythonVersion)
        try JSONEncoder().encode(state).write(to: AppPaths.state, options: .atomic)
    }
}

// MARK: Репетиция для отладочных сценариев

extension Installer {
    /// Как пройдёт репетиция: до конца, остановиться на ходе из макета (46 %) или сорваться с ошибкой сети.
    enum Rehearsal: Sendable { case complete, hold, fail }

    /// Ход установки без установки: те же шаги, подписи и доли, что у `run()`, но ничего не скачивается
    /// и диск не трогается. Только для аргументов запуска `DebugScenario` (`-NektoOnboarding`, `-NektoWelcome`):
    /// на Mac, где модель уже стоит, настоящий `run()` пересоздал бы среду Python.
    func rehearse(_ kind: Rehearsal) async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        for step in Step.allCases where status[step] == .failed { status[step] = .pending }
        let tick = Duration.milliseconds(100)
        do {
            if status[.runtime] != .done {
                set(.runtime, .running)
                for i in 1...30 {
                    report(.runtime, Double(i) / 30, i < 4 ? "Python" : "Пакеты")
                    try await Task.sleep(for: tick)
                }
                report(.runtime, 1, "")
                set(.runtime, .done)
            }
            set(.model, .running)
            let total = Manifest.modelBytes
            for i in 1...60 {
                let share = Double(i) / 60
                let done = Int64(Double(total) * share)
                report(.model, 0.97 * share, "\(RU.megabytes(done)) из \(RU.megabytes(total))")
                if share >= 0.26 && kind != .complete {
                    if kind == .fail {
                        errorMessage = SetupError.network("").errorDescription
                        set(.model, .failed)
                        return
                    }
                    try await Task.sleep(for: .seconds(3600))
                }
                try await Task.sleep(for: tick)
            }
            report(.model, 1, RU.megabytes(total))
            set(.model, .done)
            set(.check, .running)
            report(.check, 0.15, "Запускаю модель")
            try await Task.sleep(for: .milliseconds(600))
            report(.check, 0.75, "Пробный текст")
            try await Task.sleep(for: .milliseconds(600))
            report(.check, 1, "")
            set(.check, .done)
        } catch {
            return
        }
    }
}

enum SetupError: LocalizedError {
    case diskSpace(needed: Int64)
    case checksum(String)
    case toolFailed(String)
    case selftest
    case network(String)

    var errorDescription: String? {
        switch self {
        case .diskSpace(let n):
            RU.t("Не хватает места на диске. Нужно \(RU.megabytes(n)) свободного места.")
        case .checksum: RU.t("Файл модели скачался с ошибкой. Попробуйте ещё раз.")
        case .toolFailed(let m): "Не удалось установить пакеты: \(m)"
        case .selftest: RU.t("Модель установилась, но пробный текст не обработался.")
        case .network: RU.t("Нет подключения к интернету.")
        }
    }
}

/// Запуск встроенного uv с изолированными путями и без пользовательских конфигов.
struct Toolchain: Sendable {
    func run(_ args: [String]) async throws {
        let p = Process()
        p.executableURL = AppPaths.bundleUV
        p.arguments = args
        var env: [String: String] = [
            "UV_PYTHON_INSTALL_DIR": AppPaths.pythonInstall.path,
            "UV_CACHE_DIR": AppPaths.uvCache.path,
            "UV_NO_CONFIG": "1",
            "UV_PYTHON_PREFERENCE": "only-managed",
            "UV_LINK_MODE": "copy",
            "UV_NO_PROGRESS": "1",
            "UV_HTTP_TIMEOUT": "180",
            "UV_CONCURRENT_DOWNLOADS": "6",
            "HOME": NSHomeDirectory(),
            // Без /usr/bin: там заглушки git/python3/xcrun, на чистой macOS они открывают
            // диалог «Установить инструменты разработчика» (проверено на чистой macOS). uv они не нужны.
            "PATH": "/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"] {
            if let v = ProcessInfo.processInfo.environment[key] { env[key] = v }
        }
        p.environment = env
        let err = Pipe()
        let collected = DataCollector()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { collected.append(d) }
        }
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try AppPaths.ensure(AppPaths.logs)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try p.run() } catch { c.resume(throwing: SetupError.toolFailed(error.localizedDescription)) }
            }
        } onCancel: { p.terminate() }
        let tail = collected.text
        Self.log("uv \(args.joined(separator: " ")) → \(status)\n\(tail)")
        guard status == 0 else {
            if tail.localizedCaseInsensitiveContains("network") || tail.contains("dns") || tail.contains("connect") {
                throw SetupError.network(tail)
            }
            let last = tail.split(separator: "\n").last.map(String.init) ?? "код \(status)"
            throw SetupError.toolFailed(last)
        }
    }

    static func log(_ text: String) {
        let url = AppPaths.logs.appendingPathComponent("setup.log")
        let line = Data("[\(Date())] \(text)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }
}

/// Потокобезопасный сборщик вывода процесса (не даём переполниться буферу канала).
final class DataCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); if data.count > 200_000 { data = data.suffix(100_000) }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
