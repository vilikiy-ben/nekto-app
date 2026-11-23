import CryptoKit
import Foundation

enum Hashing {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Потоковый SHA-256 большого файла (модель — 1,1 ГБ) без загрузки в память.
    static func sha256Hex(fileAt url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        var hasher = SHA256()
        var read: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 4 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            read += Int64(chunk.count)
            if total > 0 { progress?(Double(read) / Double(total)) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let it = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                                                      options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in it {
            let v = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
