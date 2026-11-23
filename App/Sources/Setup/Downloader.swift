import Foundation

/// Загрузка большого файла с прогрессом, докачкой (resume data) и повторными попытками.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var resumeData: Data?
    private let lock = NSLock()
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 6 * 60 * 60
        cfg.waitsForConnectivity = true
        cfg.httpAdditionalHeaders = ["User-Agent": "\(Brand.name)/1.0 (macOS)"]
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    static func fetch(_ url: URL, expectedSize: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let d = Downloader(progress: progress)
        defer { d.session.finishTasksAndInvalidate() }
        var attempt = 0
        while true {
            do {
                let tmp = try await d.attempt(url)
                let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? 0
                guard size == expectedSize else { throw SetupError.checksum(url.lastPathComponent) }
                return tmp
            } catch {
                attempt += 1
                if Task.isCancelled || attempt >= 6 {
                    throw (error as? URLError).map { SetupError.network($0.localizedDescription) } ?? error
                }
                try await Task.sleep(for: .seconds(min(30, pow(2, Double(attempt)))))
            }
        }
    }

    private func attempt(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                lock.lock()
                continuation = c
                let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
                resumeData = nil
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            session.getAllTasks { $0.forEach { $0.cancel() } }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(SetupError.network("HTTP \(http.statusCode)")))
            return
        }
        do {
            try AppPaths.ensure(AppPaths.downloads)
            let dst = AppPaths.downloads.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: dst)
            finish(.success(dst))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        lock.unlock()
        finish(.failure(error))
    }
}
