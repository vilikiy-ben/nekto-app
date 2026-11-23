import Foundation

/// Всё, что ставится на первом запуске, закреплено здесь: версии, адреса и SHA-256.
enum Manifest {
    static let pythonVersion = "3.11.18"
    /// Меняется вместе с Engine/requirements.lock — установленное окружение пересоздаётся.
    static var lockDigest: String {
        guard let url = Bundle.main.url(forResource: "requirements", withExtension: "lock", subdirectory: "engine"),
              let data = try? Data(contentsOf: url) else { return "dev" }
        return Hashing.sha256Hex(data)
    }

    /// Модель — redmadrobot-rnd/rubert-base-pii-ner (Apache-2.0) в ONNX-экспорте lockR/rubert-base-pii-ner-onnx.
    /// Ревизия экспорта закреплена, у каждого файла — размер и SHA-256. Этот же файл сверен с исходными весами
    /// модели: одни и те же метки на 76 714 токенах.
    static let modelRepo = "lockR/rubert-base-pii-ner-onnx"
    static let modelRevision = "ea7610b22808c509c0c8b7c7b0f6639c19684d08"
    static let modelFolder = "ea7610b"

    struct ModelFile: Sendable {
        let path: String
        let size: Int64
        let sha256: String
        var url: URL {
            URL(string: "https://huggingface.co/\(Manifest.modelRepo)/resolve/\(Manifest.modelRevision)/\(path)")!
        }
    }

    static let modelFiles: [ModelFile] = [
        .init(path: "config.json", size: 2_831, sha256: "f4eeba88d1503a56d629195c9307d42c1acf4ce53ab88fdaecfc754fd0745cf9"),
        .init(path: "tokenizer.json", size: 3_714_701, sha256: "f61eee9d0dc18f14c195321a37eadf9e5aeb3a323bc278dec689adeb89dec1b9"),
        .init(path: "model.optimized.fp32.onnx", size: 711_034_332, sha256: "eebed6562883ca6c59204da661ddb3edb1b334e91737f35d79ac74c75d371315"),
    ]
    static var modelBytes: Int64 { modelFiles.reduce(0) { $0 + $1.size } }

    /// Ориентиры для честного прогресса установки окружения (замерено на чистой установке).
    static let pythonBytes: Int64 = 77_000_000
    static let downloadBytes: Int64 = 167_000_000
    static let venvBytes: Int64 = 161_000_000
    /// Сколько свободного места нужно: модель (0,7 ГБ) + её веса отдельным файлом для отображения в память (0,7 ГБ,
    /// `Engine/nekto_engine/model/mapped.py`) + окружение + запас на кеш загрузки.
    static let requiredFreeBytes: Int64 = 2_400_000_000
}

/// Пути приложения. Что лежит в «Библиотеке» и под каким именем — `Footprint.current`.
enum AppPaths {
    static let support = Footprint.current.support
    static let caches = Footprint.current.caches
    static var runtime: URL { support.appendingPathComponent("runtime", isDirectory: true) }
    static var pythonInstall: URL { runtime.appendingPathComponent("python", isDirectory: true) }
    static var venv: URL { runtime.appendingPathComponent("venv", isDirectory: true) }
    static var venvPython: URL { venv.appendingPathComponent("bin/python") }
    static var models: URL { support.appendingPathComponent("model", isDirectory: true) }
    static var model: URL { models.appendingPathComponent(Manifest.modelFolder, isDirectory: true) }
    static var state: URL { support.appendingPathComponent("state.json") }
    static let logs = Footprint.current.logs
    static var uvCache: URL { caches.appendingPathComponent("uv-cache", isDirectory: true) }
    static var downloads: URL { caches.appendingPathComponent("downloads", isDirectory: true) }

    static var bundleEngine: URL { Bundle.main.resourceURL!.appendingPathComponent("engine", isDirectory: true) }
    static var bundleUV: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/uv") }
    static var sandboxProfile: URL { Bundle.main.url(forResource: "engine-sandbox", withExtension: "sb")! }

    static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
