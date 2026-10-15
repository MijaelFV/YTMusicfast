import Foundation
import Observation
import os

private let downloadLog = Logger(subsystem: "dev.ytmusicfast", category: "Downloads")

/// Albums and playlists saved for offline listening (YouTube Music's Download toggle).
///
/// Files live in Application Support, apart from the replay cache, so they're never evicted.
/// Playback finds them through `AudioCache.cachedFile`, and a downloaded page opens offline
/// from the track list saved with it.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    struct Collection: Codable, Identifiable {
        var item: MediaItem
        var header: PageHeader?
        var tracks: [Track]
        var id: String { item.target.browseId }
    }

    enum State: Equatable {
        case none
        /// Fraction of the collection's songs on disk.
        case downloading(Double)
        case downloaded
    }

    private(set) var collections: [Collection] = []
    /// Songs with a file on disk.
    private(set) var downloaded: Set<String> = []
    /// Songs waiting or in progress.
    private(set) var pending: [Track] = []
    private var running: Set<String> = []
    /// Songs that failed once get one more try after the rest.
    private var retried: Set<String> = []
    private let maxConcurrent = 2

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("YTMusicfast/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    nonisolated static func fileURL(for videoId: String) -> URL {
        directory.appendingPathComponent("\(videoId).m4a")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? JSONDecoder().decode([Collection].self, from: data) {
            collections = saved
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        downloaded = Set(files.filter { $0.hasSuffix(".m4a") }.map { String($0.dropLast(4)) })
        // Finish whatever was interrupted by quitting.
        let missing = collections.flatMap(\.tracks).filter { !downloaded.contains($0.videoId) }
        if !missing.isEmpty { enqueue(missing) }
    }

    // MARK: Queries

    func collection(for target: BrowseTarget) -> Collection? {
        collections.first { $0.item.target.browseId == target.browseId }
    }

    func state(for target: BrowseTarget) -> State {
        guard let collection = collection(for: target) else { return .none }
        let waiting = Set(pending.map(\.videoId)).union(running)
        // Songs that couldn't be downloaded (removed, region-locked) don't hold the collection back.
        guard collection.tracks.contains(where: { waiting.contains($0.videoId) }) else { return .downloaded }
        let done = collection.tracks.filter { downloaded.contains($0.videoId) }.count
        return .downloading(Double(done) / Double(max(1, collection.tracks.count)))
    }

    func isDownloaded(_ track: Track) -> Bool { downloaded.contains(track.videoId) }

    /// A downloaded collection as a page, for opening it offline.
    func page(for target: BrowseTarget) -> BrowsePage? {
        guard let collection = collection(for: target) else { return nil }
        var page = BrowsePage()
        page.kind = target.kind
        page.header = collection.header ?? PageHeader(title: collection.item.title, subtitle: collection.item.subtitle,
                                                      thumbnail: collection.item.thumbnail)
        page.shelves = [Shelf(style: .list, items: collection.tracks.map(ShelfItem.track), isPlaylistContents: true)]
        return page
    }

    var totalBytes: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "m4a" }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: Changes

    func download(_ item: MediaItem, header: PageHeader?, tracks: [Track]) {
        let playable = tracks.filter { !$0.videoId.isEmpty }
        guard !playable.isEmpty else { return }
        if let index = collections.firstIndex(where: { $0.id == item.target.browseId }) {
            collections[index].tracks = playable
            collections[index].header = header ?? collections[index].header
        } else {
            collections.insert(Collection(item: item, header: header, tracks: playable), at: 0)
        }
        save()
        enqueue(playable)
        Router.shared.showToast(String(localized: "Downloading \(item.title)"), icon: "arrow.down.circle.fill")
    }

    func remove(_ target: BrowseTarget) {
        guard let removed = collection(for: target) else { return }
        collections.removeAll { $0.id == target.browseId }
        save()
        // Keep songs another downloaded collection still needs.
        let stillNeeded = Set(collections.flatMap(\.tracks).map(\.videoId))
        let orphaned = removed.tracks.map(\.videoId).filter { !stillNeeded.contains($0) }
        pending.removeAll { orphaned.contains($0.videoId) }
        for id in orphaned {
            try? FileManager.default.removeItem(at: Self.fileURL(for: id))
            downloaded.remove(id)
        }
        Router.shared.showToast(String(localized: "Removed download"), icon: "arrow.down.circle") { [weak self] in
            self?.download(removed.item, header: removed.header, tracks: removed.tracks)
        }
    }

    func removeAll() {
        pending.removeAll()
        for id in downloaded { try? FileManager.default.removeItem(at: Self.fileURL(for: id)) }
        downloaded.removeAll()
        collections.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(collections) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    // MARK: Worker

    private func enqueue(_ tracks: [Track]) {
        let known = Set(pending.map(\.videoId)).union(running).union(downloaded)
        var seen = Set<String>()
        pending += tracks.filter { !known.contains($0.videoId) && seen.insert($0.videoId).inserted }
        pump()
    }

    private func pump() {
        while running.count < maxConcurrent, !pending.isEmpty {
            let track = pending.removeFirst()
            running.insert(track.videoId)
            Task {
                let ok = await Self.fetch(track)
                running.remove(track.videoId)
                if ok {
                    downloaded.insert(track.videoId)
                } else if !retried.contains(track.videoId),
                          collections.contains(where: { $0.tracks.contains { $0.videoId == track.videoId } }) {
                    retried.insert(track.videoId)
                    pending.append(track)
                }
                pump()
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// One stream's bytes, in ranged chunks. Stream URLs can start refusing (403) or expire
    /// mid-download; then a fresh one is resolved and the download carries on.
    private nonisolated static func download(_ track: Track, info: inout StreamInfo, opus: Bool) async throws -> Data {
        let resolver = ChainedStreamResolver.shared
        func stream(_ info: StreamInfo) -> (url: URL, length: Int)? {
            opus ? info.opus.map { ($0.url, $0.contentLength) } : (info.url, info.contentLength)
        }
        guard var (url, length) = stream(info) else { throw InnerTubeError.noAudio }
        let chunk = 1 << 20
        var data = Data(capacity: length)
        var start = 0
        while start < length {
            try Task.checkCancellation()
            let end = min(length, start + chunk) - 1
            var attempt = 0
            while true {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "range", value: "\(start)-\(end)")]
                var request = URLRequest(url: components.url!)
                request.setValue(InnerTube.safariUserAgent, forHTTPHeaderField: "User-Agent")
                let status: Int
                do {
                    let (bytes, response) = try await session.data(for: request)
                    status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if (200..<300).contains(status), bytes.count == end - start + 1 {
                        data.append(bytes)
                        break
                    }
                } catch {
                    status = 0
                }
                attempt += 1
                guard attempt <= 5 else { throw InnerTubeError.http(status) }
                if status == 403 || attempt >= 2 {
                    // A refused or failing URL: get a fresh one (same file, same length).
                    await resolver.invalidate(track.videoId)
                    let fresh = try await resolver.resolve(videoId: track.videoId)
                    guard let next = stream(fresh), next.length == length else { throw InnerTubeError.noAudio }
                    info = fresh
                    url = next.url
                }
                try await Task.sleep(for: .milliseconds(400 * attempt))
            }
            start = end + 1
        }
        return data
    }

    /// Copies the song from the replay cache when it's there, else downloads it in ranged chunks
    /// (a whole-file request is throttled to about realtime). Stream URLs can start refusing
    /// (403) or expire mid-download; then a fresh one is resolved and the download carries on.
    private nonisolated static func fetch(_ track: Track) async -> Bool {
        let destination = fileURL(for: track.videoId)
        if FileManager.default.fileExists(atPath: destination.path) { return true }
        if let cached = AudioCache.replayCacheFile(for: track.videoId) {
            do {
                try FileManager.default.copyItem(at: cached, to: destination)
                return true
            } catch {}
        }
        let resolver = ChainedStreamResolver.shared
        do {
            var info = try await resolver.resolve(videoId: track.videoId)
            if let loudness = info.loudnessDb { AudioCache.setLoudness(loudness, for: track.videoId) }
            if let length = info.duration { AudioCache.setDuration(length, for: track.videoId) }
            // The better Opus audio, repackaged as MP4 (see WebMOpus); the AAC if that doesn't work.
            if info.opus != nil, let webm = try? await download(track, info: &info, opus: true),
               let layout = WebMOpus.layout(webm) {
                try WebMOpus.data(layout, from: webm).write(to: destination, options: .atomic)
                return true
            }
            let data = try await download(track, info: &info, opus: false)
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            downloadLog.error("download \(track.videoId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
