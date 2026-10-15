import CryptoKit
import Foundation

/// The last copy of pages and lists, kept on disk so the app opens on what you saw last time and
/// refreshes it in the background ("last-known content").
///
/// Nothing is kept in memory here: reads decode straight into the caller's copy, writes are
/// coalesced per key and done off the main thread. The folder is capped by size, oldest first.
enum DiskCache {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("YTMusicfast/pages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Total budget for cached pages; a huge Liked Music is ~2 MB.
    private static let maxBytes = 40 * 1024 * 1024
    private static let queue = DispatchQueue(label: "dev.ytmusicfast.diskcache", qos: .utility)
    /// Writes waiting to happen, by key: only the newest value of each is encoded and written,
    /// so a long playlist loading in many batches is saved once. Values share storage with the
    /// caller's copy (copy-on-write), so waiting here costs no extra memory.
    nonisolated(unsafe) private static var pending: [String: any Encodable & Sendable] = [:]
    nonisolated(unsafe) private static var scheduled = false
    private static let lock = NSLock()

    private static func file(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    /// The cached value and when it was saved, decoded off the main thread.
    static func load<T: Decodable & Sendable>(_ type: T.Type, key: String) async -> (value: T, saved: Date)? {
        let url = file(for: key)
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let data = try? Data(contentsOf: url),
                      let value = try? JSONDecoder().decode(T.self, from: ScreenshotNames.apply(data)) else {
                    continuation.resume(returning: nil)
                    return
                }
                let saved = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                continuation.resume(returning: (value, saved))
            }
        }
    }

    /// Saves a value soon. Repeated saves of the same key within two seconds write once.
    static func store<T: Encodable & Sendable>(_ value: T, key: String) {
        lock.lock()
        pending[key] = value
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.asyncAfter(deadline: .now() + 2, execute: flush) }
    }

    static func remove(key: String) {
        lock.lock()
        pending[key] = nil
        lock.unlock()
        queue.async { try? FileManager.default.removeItem(at: file(for: key)) }
    }

    /// Everything (Settings → Storage, signing out).
    static func clear() {
        lock.lock()
        pending = [:]
        lock.unlock()
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in files { try? FileManager.default.removeItem(at: url) }
        }
    }

    static var totalBytes: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    private static func flush() {
        lock.lock()
        let batch = pending
        pending = [:]
        scheduled = false
        lock.unlock()
        let encoder = JSONEncoder()
        for (key, value) in batch {
            guard let data = try? encoder.encode(value) else { continue }
            try? data.write(to: file(for: key), options: .atomic)
        }
        trim()
    }

    private static func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard var files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        var total = files.reduce(0) { $0 + size($1) }
        guard total > maxBytes else { return }
        files.sort {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }
        for url in files where total > maxBytes {
            total -= size(url)
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// For README screenshots: names swapped in everything YouTube sends and the cache holds, so your
/// own never shows (`defaults write dev.ytmusicfast.app screenshotNames -dict "Your Name" "John Doe"`).
/// Debug builds only; a release build passes data straight through.
enum ScreenshotNames {
    static func apply(_ data: Data) -> Data {
        #if DEBUG
        guard let names = UserDefaults.standard.dictionary(forKey: "screenshotNames") as? [String: String], !names.isEmpty,
              var text = String(data: data, encoding: .utf8) else { return data }
        for (real, shown) in names { text = text.replacingOccurrences(of: real, with: shown) }
        return Data(text.utf8)
        #else
        return data
        #endif
    }
}
