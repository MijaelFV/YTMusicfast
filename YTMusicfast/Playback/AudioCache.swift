import Foundation

/// On-disk LRU cache of fully downloaded tracks (`~/Library/Caches/YTMusicfast/audio`).
enum AudioCache {
    /// The size you picked (Settings → Storage), 2 GB unless changed.
    static var chosenLimit: Int {
        let gigabytes = UserDefaults.standard.object(forKey: "replayCacheGB") as? Double ?? 2
        return Int(gigabytes * 1_073_741_824)
    }

    /// The size to keep: what you picked, but never more than a quarter of the disk's free space
    /// (counting the cache itself), so a filling disk gets its room back.
    static var maxBytes: Int {
        let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map(Int.init) ?? Int.max / 2
        return max(256 << 20, min(chosenLimit, (free + totalBytes) / 4))
    }

    static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("YTMusicfast/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Songs still downloading (ChunkedAudioSource writes them here, then they're adopted).
    static let partialDirectory: URL = {
        let dir = directory.appendingPathComponent("partial", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A fully downloaded song becomes the cached copy, moved into place (no copy).
    static func adopt(_ file: URL, videoId: String) {
        let destination = fileURL(for: videoId)
        try? FileManager.default.removeItem(at: destination)
        if (try? FileManager.default.moveItem(at: file, to: destination)) == nil {
            try? FileManager.default.removeItem(at: file)
        }
        trimSoon()
    }

    private static let trimLock = NSLock()
    nonisolated(unsafe) private static var lastTrim = Date.distantPast

    /// Keeps the cache within its size during long sessions too, not only at launch (at most every
    /// few minutes, off the main thread).
    static func trimSoon() {
        let due = trimLock.withLock {
            guard Date().timeIntervalSince(lastTrim) > 300 else { return false }
            lastTrim = Date()
            return true
        }
        guard due else { return }
        DispatchQueue.global(qos: .utility).async { trim(pruningMetadata: false) }
    }

    private static func fileURL(for videoId: String) -> URL {
        directory.appendingPathComponent("\(videoId).m4a")
    }

    /// The song's audio on disk: a download, else the replay cache.
    static func cachedFile(for videoId: String) -> URL? {
        let download = DownloadManager.fileURL(for: videoId)
        if FileManager.default.fileExists(atPath: download.path) { return download }
        return replayCacheFile(for: videoId)
    }

    /// Whether the song plays offline (downloaded or cached) — without touching the file's date.
    static func isAvailable(_ videoId: String) -> Bool {
        FileManager.default.fileExists(atPath: DownloadManager.fileURL(for: videoId).path)
            || FileManager.default.fileExists(atPath: fileURL(for: videoId).path)
    }

    /// Returns the replay-cache file and bumps its recency.
    static func replayCacheFile(for videoId: String) -> URL? {
        let url = fileURL(for: videoId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    static var totalBytes: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension == "m4a" } ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "m4a" } ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Downloads interrupted by a quit or crash (called at launch, before any are in progress).
    static func removeStalePartials() {
        let files = (try? FileManager.default.contentsOfDirectory(at: partialDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    static func store(_ data: Data, videoId: String) {
        try? data.write(to: fileURL(for: videoId), options: .atomic)
    }

    /// Drops least-recently-played files once the cache grows past `maxBytes`.
    static func trim(pruningMetadata: Bool = true) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys))?
            .filter({ $0.pathExtension == "m4a" }) else { return }
        let entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        let limit = maxBytes
        for (url, _, size) in entries.sorted(by: { $0.1 < $1.1 }) where total > limit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
        // Only at launch: mid-session, a song resolved for later may not be cached yet.
        if pruningMetadata { pruneMetadata() }
    }

    /// Loudness and length are kept for songs on this Mac (cached or downloaded) — not for every
    /// song ever played, which would grow the settings file forever. Others get theirs again
    /// when they play.
    private static func pruneMetadata() {
        for key in [loudnessKey, durationKey] {
            guard let map = UserDefaults.standard.dictionary(forKey: key) as? [String: Double], map.count > 300 else { continue }
            let kept = map.filter { isAvailable($0.key) }
            if kept.count < map.count { UserDefaults.standard.set(kept, forKey: key) }
        }
    }

    // MARK: Per-track metadata (lets cached tracks play without re-resolving the stream)

    private static let loudnessKey = "loudnessDb"
    private static let durationKey = "durations"

    static func loudness(for videoId: String) -> Double? { value(loudnessKey, videoId) }
    static func setLoudness(_ value: Double, for videoId: String) { set(loudnessKey, videoId, value) }

    static func duration(for videoId: String) -> TimeInterval? { value(durationKey, videoId) }

    /// Every known length at once (one read, for filling in a whole list).
    static func durations() -> [String: TimeInterval] {
        (UserDefaults.standard.dictionary(forKey: durationKey) as? [String: Double]) ?? [:]
    }

    static func setDuration(_ value: TimeInterval, for videoId: String) { set(durationKey, videoId, value) }

    /// A replay copy below Premium quality (saved before Premium audio, or on another account):
    /// worth fetching again for a Premium account. Downloads aren't touched.
    static func isBelowPremium(_ videoId: String) -> Bool {
        guard let size = (try? fileURL(for: videoId).resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              let seconds = duration(for: videoId), seconds > 0 else { return false }
        return Double(size) * 8 / seconds < 200_000
    }

    private static func value(_ key: String, _ videoId: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[videoId]
    }

    private static func set(_ key: String, _ videoId: String, _ value: Double) {
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        map[videoId] = value
        UserDefaults.standard.set(map, forKey: key)
    }
}
