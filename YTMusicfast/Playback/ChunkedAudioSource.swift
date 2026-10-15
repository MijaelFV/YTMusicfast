import AVFoundation
import Foundation

/// Feeds AVPlayer from YouTube's CDN in small ranged chunks.
///
/// Requesting a whole stream in one go is throttled to ~2x realtime; asking for 1 MB
/// slices via the `&range=` query parameter downloads a full song in about a second.
/// Chunks are served to AVPlayer as soon as they land (seeks jump the line).
///
/// Chunks go straight to a file on disk, not memory: a two-hour podcast would otherwise hold
/// over 100 MB (twice, while the replay copy was assembled). Once every chunk is in, that file
/// becomes the replay cache as it is — no copy.
///
/// Songs download YouTube's Opus stream when there is one (better than its AAC) and are
/// repackaged as MP4 once complete (see WebMOpus) — AVFoundation reads a song whole before
/// playing anyway, so this costs no waiting. Anything unexpected falls back to the AAC stream.
final class ChunkedAudioSource: NSObject, AVAssetResourceLoaderDelegate, HLSSource, @unchecked Sendable {
    static let scheme = "ytfast-audio"

    let videoId: String
    private var info: StreamInfo
    private let refresh: @Sendable () async throws -> StreamInfo

    // Everything below is confined to `queue`.
    private let queue: DispatchQueue
    private let chunkSize: Int
    /// Streamed piece by piece from the start (a slow connection), not downloaded whole first.
    private let streaming: Bool
    private let maxConcurrent = 3
    /// Files up to this many chunks (~25 minutes at 128 kbps — nearly every song) are fetched
    /// whole: instant seeks, gapless, a replay copy. Longer recordings (podcasts, hour-long mixes,
    /// 12-hour streams) only keep `readAhead` chunks ahead of where you're listening.
    private let wholeFileChunks = 24
    private let readAhead = 16
    /// Where the player last needed data (windowed recordings fetch from here).
    private var playhead = 0
    /// Chunks written to `partFile`.
    private var available: Set<Int> = []
    /// Chunks the disk refused (full disk): kept in memory instead, so playback goes on.
    private var inMemory: [Int: Data] = [:]
    private var partFile: FileHandle?
    private var partURL: URL
    /// Playing the Opus variant (songs only): downloaded whole, then served as `converted`.
    private var opus: StreamInfo.Variant?
    private var converted: Converted?
    /// Bumped when the download starts over in another format: late answers for the old one
    /// are ignored.
    private var generation = 0
    private var tasks: [Int: URLSessionDataTask] = [:]
    private var failures: [Int: Int] = [:]
    private var requests: [AVAssetResourceLoadingRequest] = []
    /// Long recordings: the file's fragment index, and requests from the HLS server waiting for
    /// bytes still downloading.
    private var index: FragmentedMP4.Index?
    private var waiters: [(range: ClosedRange<Int>, continuation: CheckedContinuation<Data?, Never>)] = []
    /// The total size (it never changes, even when the address is refreshed).
    let contentLength: Int
    /// Called when this source is done with (the HLS server forgets it).
    var onRelease: (() -> Void)?
    private var refreshing = false
    /// Fresh addresses asked for since a chunk last got through. Refused again and again means
    /// YouTube is refusing the stream itself, not that an address expired.
    private var refreshesWithoutProgress = 0
    private var completed = false
    private var cancelled = false
    /// Players waiting for a song's repackaged file (see `finishedFile`).
    private var fileWaiters: [UUID: CheckedContinuation<URL?, Never>] = [:]
    private let created = Date()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private enum Converted {
        case file(FileHandle, length: Int)
        case memory(Data)

        var length: Int {
            switch self {
            case .file(_, let length): length
            case .memory(let data): data.count
            }
        }
    }

    /// `streaming`: on a slow connection, play as the pieces arrive (smaller ones, so the first
    /// comes sooner) instead of after the whole song — at the cost of the equalizer and
    /// crossfade for that song (see HLSServer).
    init(videoId: String, info: StreamInfo, streaming: Bool = false, refresh: @escaping @Sendable () async throws -> StreamInfo) {
        self.videoId = videoId
        self.info = info
        self.streaming = streaming
        chunkSize = streaming ? 1 << 18 : 1 << 20
        contentLength = info.contentLength
        self.refresh = refresh
        queue = DispatchQueue(label: "ytfast.audio.\(videoId)")
        partURL = Self.newPartURL(videoId)
        // Only songs (fetched whole); long recordings stream the AAC piece by piece.
        if !streaming, let opus = info.opus, (opus.contentLength + chunkSize - 1) / chunkSize <= wholeFileChunks { self.opus = opus }
    }

    private static func newPartURL(_ videoId: String) -> URL {
        AudioCache.partialDirectory.appendingPathComponent("\(videoId)-\(UUID().uuidString).part")
    }

    /// The file being downloaded: its address and size.
    private var streamURL: URL { opus?.url ?? info.url }
    private var length: Int { opus?.contentLength ?? info.contentLength }

    deinit {
        try? partFile?.close()
        if !completed { try? FileManager.default.removeItem(at: partURL) }
        onRelease?()
    }

    private var chunkCount: Int { (length + chunkSize - 1) / chunkSize }

    /// The asset for the player: the file itself for songs; for long recordings, HLS from this Mac
    /// (see HLSServer), which AVFoundation fetches a piece at a time. Falls back to the file if it
    /// has no index.
    func makeAsset() async -> AVURLAsset {
        if !fetchesWholeFile, await loadIndex(), let url = try? await HLSServer.shared.playlistURL(for: self) {
            return AVURLAsset(url: url)
        }
        if let file = await finishedFile() { return AVURLAsset(url: file) }
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://\(videoId).m4a")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Fetches the first chunk (header and index) and reads the index. False if there's none.
    private func loadIndex() async -> Bool {
        for _ in 0..<40 {
            if Task.isCancelled { return false }
            let found: Bool? = await withCheckedContinuation { continuation in
                queue.async {
                    if let index = self.index { continuation.resume(returning: !index.segments.isEmpty); return }
                    if self.has(0), let head = self.read(chunk: 0, from: 0, to: min(self.chunkSize, self.info.contentLength)) {
                        self.index = FragmentedMP4.index(in: head) ?? FragmentedMP4.Index(header: 0..<0, segments: [])
                        continuation.resume(returning: !(self.index?.segments.isEmpty ?? true))
                        return
                    }
                    if self.cancelled { continuation.resume(returning: false); return }
                    self.pump(from: 0)
                    continuation.resume(returning: nil)
                }
            }
            if let found { return found }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    /// An Opus song plays from its repackaged file in the replay cache, once that's written:
    /// whatever reaches AVFoundation through the resource loader stays in its memory (the whole
    /// song, and again for the next one queued), while a file is read from disk as needed. The
    /// player can't start before the whole song is in either way. Nil when there's no such file
    /// (not an Opus song, it fell back to AAC or memory, it failed, or it was skipped past): the
    /// resource loader serves it then.
    private func finishedFile() async -> URL? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard self.opus != nil, !self.cancelled else { continuation.resume(returning: nil); return }
                    if let converted = self.converted {
                        guard case .file = converted else { continuation.resume(returning: nil); return }
                        continuation.resume(returning: AudioCache.replayCacheFile(for: self.videoId))
                        return
                    }
                    self.fileWaiters[id] = continuation
                    self.pump(from: nil)
                }
            }
        } onCancel: {
            queue.async { self.fileWaiters.removeValue(forKey: id)?.resume(returning: nil) }
        }
    }

    private func resumeFileWaiters(with file: URL?) {
        fileWaiters.values.forEach { $0.resume(returning: file) }
        fileWaiters = [:]
    }

    /// Starts downloading the whole track in the background (used for the up-next track).
    func prefetch() {
        queue.async { self.pump(from: 0) }
    }

    /// Whether the whole file is fetched (songs) or only a window ahead (long recordings).
    var fetchesWholeFile: Bool { !streaming && chunkCount <= wholeFileChunks }

    /// Every byte is in (and, for Opus, repackaged).
    var isComplete: Bool { queue.sync { completed } }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.waiters.forEach { $0.continuation.resume(returning: nil) }
            self.waiters = []
            self.resumeFileWaiters(with: nil)
            self.onRelease?()
            self.onRelease = nil
            self.tasks.values.forEach { $0.cancel() }
            self.tasks.removeAll()
            try? self.partFile?.close()
            self.partFile = nil
            if !self.completed { try? FileManager.default.removeItem(at: self.partURL) }
            self.available = []
            self.inMemory = [:]
            if case .file(let handle, _) = self.converted { try? handle.close() }
            self.converted = nil
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        requests.append(loadingRequest)
        serve()
        return true
    }

    // MARK: HLS (long recordings)

    /// The HLS playlist of the file's fragments.
    func playlist() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let index = self.index, !index.segments.isEmpty else { continuation.resume(returning: nil); return }
                continuation.resume(returning: FragmentedMP4.playlist(for: index, mediaName: "media.mp4"))
            }
        }
    }

    /// Bytes of the file, once downloaded (nil if it can't be, e.g. offline for long).
    func bytes(_ range: ClosedRange<Int>) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.cancelled else { continuation.resume(returning: nil); return }
                self.waiters.append((range, continuation))
                self.serveWaiters()
                // The player moved here: fetch from here.
                let first = range.lowerBound / self.chunkSize
                self.pump(from: (first...(range.upperBound / self.chunkSize)).first { !self.has($0) } ?? first)
            }
        }
    }

    private func serveWaiters() {
        waiters.removeAll { waiter in
            let chunks = (waiter.range.lowerBound / chunkSize)...(waiter.range.upperBound / chunkSize)
            guard chunks.allSatisfy(has) else { return false }
            var data = Data(capacity: waiter.range.count)
            var offset = waiter.range.lowerBound
            while offset <= waiter.range.upperBound {
                let index = offset / chunkSize
                let upTo = min(waiter.range.upperBound + 1, (index + 1) * chunkSize)
                guard let piece = read(chunk: index, from: offset, to: upTo) else {
                    waiter.continuation.resume(returning: nil)
                    return true
                }
                data += piece
                offset = upTo
            }
            waiter.continuation.resume(returning: data)
            return true
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        requests.removeAll { $0 === loadingRequest }
    }

    // MARK: Storage

    private func has(_ index: Int) -> Bool { available.contains(index) || inMemory[index] != nil }

    private func store(_ data: Data, at index: Int) {
        do {
            if partFile == nil {
                try FileManager.default.createDirectory(at: AudioCache.partialDirectory, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
                partFile = try FileHandle(forUpdating: partURL)
            }
            try partFile?.seek(toOffset: UInt64(index * chunkSize))
            try partFile?.write(contentsOf: data)
            available.insert(index)
        } catch {
            inMemory[index] = data
        }
    }

    /// Bytes `start..<end` of one chunk (from disk, or memory if the disk refused it).
    private func read(chunk index: Int, from start: Int, to end: Int) -> Data? {
        let base = index * chunkSize
        if let data = inMemory[index] { return data.subdata(in: (start - base)..<(end - base)) }
        guard available.contains(index), let partFile else { return nil }
        do {
            try partFile.seek(toOffset: UInt64(start))
            return try partFile.read(upToCount: end - start)
        } catch {
            // Lost from disk somehow: fetch it again.
            available.remove(index)
            return nil
        }
    }

    // MARK: Serving

    private func serve() {
        if opus != nil {
            serveConverted()
            return
        }
        var neededChunk: Int?
        requests.removeAll { request in
            if let contentInfo = request.contentInformationRequest {
                contentInfo.contentType = AVFileType.m4a.rawValue
                contentInfo.contentLength = Int64(info.contentLength)
                contentInfo.isByteRangeAccessSupported = true
            }
            guard let dataRequest = request.dataRequest else {
                request.finishLoading()
                return true
            }

            let end = dataRequest.requestsAllDataToEndOfResource
                ? info.contentLength
                : min(info.contentLength, Int(dataRequest.requestedOffset) + dataRequest.requestedLength)
            var offset = Int(dataRequest.currentOffset)

            while offset < end, has(offset / chunkSize) {
                let index = offset / chunkSize
                let upTo = min(end, (index + 1) * chunkSize, info.contentLength)
                guard let data = read(chunk: index, from: offset, to: upTo), data.count == upTo - offset else { break }
                dataRequest.respond(with: data)
                offset = upTo
            }

            if offset >= end {
                request.finishLoading()
                return true
            }
            if neededChunk == nil { neededChunk = offset / chunkSize }
            return false
        }
        pump(from: neededChunk)
    }

    /// Keeps up to `maxConcurrent` chunk downloads running, starting at the chunk the player needs
    /// (else where it last was): the whole file for songs, a window ahead for long recordings.
    private func pump(from needed: Int?) {
        guard !cancelled, !refreshing, converted == nil, chunkCount > 0 else { return }
        if let needed { playhead = min(max(0, needed), chunkCount - 1) }
        let order: [Int]
        if fetchesWholeFile {
            order = Array(playhead..<chunkCount) + Array(0..<playhead)
        } else {
            order = Array(playhead..<min(chunkCount, playhead + readAhead))
        }
        for index in order where tasks.count < maxConcurrent {
            if !has(index), tasks[index] == nil { fetch(index) }
        }
    }

    private func fetch(_ index: Int) {
        let start = index * chunkSize
        let end = min(length, start + chunkSize) - 1
        let generation = generation
        let address = streamURL
        let started = Date()
        var components = URLComponents(url: address, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "range", value: "\(start)-\(end)")]
        var request = URLRequest(url: components.url!)
        request.setValue(InnerTube.safariUserAgent, forHTTPHeaderField: "User-Agent")

        let task = Self.session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation else { return }
                self.tasks[index] = nil
                guard !self.cancelled else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                if var data, (200..<300).contains(status), data.count == end - start + 1 {
                    // The header is in the first piece: correct its stated length before the
                    // player sees it (see FragmentedMP4).
                    if index == 0, self.opus == nil { FragmentedMP4.fixHeaderDurations(&data) }
                    NetworkSpeed.shared.record(bytes: data.count, seconds: Date().timeIntervalSince(started))
                    self.store(data, at: index)
                    self.failures[index] = nil
                    self.refreshesWithoutProgress = 0
                    self.finishIfComplete()
                    self.serveWaiters()
                    self.serve()
                } else if status == 403 {
                    // Refused at an address already replaced: try again at the new one.
                    if address == self.streamURL { self.refused() } else { self.serve() }
                } else if (error as? URLError)?.code != .cancelled {
                    let count = (self.failures[index] ?? 0) + 1
                    self.failures[index] = count
                    if count > 3 {
                        // Tell the player (it decides: wait for the network, or skip), and start
                        // the count again so a later attempt gets its retries.
                        self.failures[index] = 0
                        self.failAll(error ?? InnerTubeError.http(status))
                    } else {
                        self.queue.asyncAfter(deadline: .now() + 0.4 * Double(count)) { self.serve() }
                    }
                }
            }
        }
        tasks[index] = task
        task.resume()
    }

    /// YouTube refused a chunk (403). Usually the address expired (they last a few hours): get a
    /// fresh one. Refused even so: the Opus stream gives way to the AAC one; the AAC one gives up
    /// and tells the player, instead of asking forever.
    private func refused() {
        guard !refreshing else { return }
        if refreshesWithoutProgress >= (opus != nil ? 1 : 2) {
            if opus != nil { fallBackToAAC() } else { failAll(InnerTubeError.http(403)) }
            return
        }
        refreshesWithoutProgress += 1
        refreshStream()
    }

    /// Stream URLs expire after a few hours; fetch a fresh one and carry on.
    private func refreshStream() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let result: Result<StreamInfo, Error>
            do { result = .success(try await refresh()) } catch { result = .failure(error) }
            queue.async {
                self.refreshing = false
                switch result {
                case .success(let fresh) where self.opus != nil:
                    self.info = fresh
                    if let opus = fresh.opus, opus.contentLength == self.length {
                        self.opus = opus
                        self.serve()
                    } else {
                        self.fallBackToAAC()
                    }
                case .success(let fresh) where fresh.contentLength == self.info.contentLength:
                    self.info = fresh
                    self.serve()
                case .success:
                    self.failAll(InnerTubeError.noAudio)
                case .failure(let error):
                    // Keeps the real reason (offline vs. unplayable) for the player.
                    self.failAll(error)
                }
            }
        }
    }

    private func failAll(_ error: Error) {
        requests.forEach { $0.finishLoading(with: error) }
        requests.removeAll()
        waiters.forEach { $0.continuation.resume(returning: nil) }
        waiters = []
        resumeFileWaiters(with: nil)
    }

    /// Every chunk is in: the file becomes the replay cache (moved, not copied; reading from the
    /// still-open handle goes on working).
    private func finishIfComplete() {
        guard !completed, available.count + inMemory.count == chunkCount else { return }
        if opus != nil {
            convert()
            return
        }
        completed = true
        perfLog.notice("downloaded \(self.videoId, privacy: .public) \(self.length) bytes in \(Int(Date().timeIntervalSince(self.created) * 1000)) ms")
        if inMemory.isEmpty, let partFile {
            try? partFile.synchronize()
            AudioCache.adopt(partURL, videoId: videoId)
        } else {
            // Some chunks only made it to memory (full disk): nothing to keep.
            try? FileManager.default.removeItem(at: partURL)
        }
    }

    // MARK: Opus

    /// The whole Opus file is in: repackage it as MP4 (a replay cache file like any other) and
    /// answer the player from that.
    private func convert() {
        let webm: Data
        if inMemory.isEmpty, let partFile {
            try? partFile.synchronize()
            webm = (try? Data(contentsOf: partURL, options: .alwaysMapped)) ?? Data()
        } else {
            var assembled = Data(capacity: length)
            for index in 0..<chunkCount {
                guard let piece = read(chunk: index, from: index * chunkSize, to: min(length, (index + 1) * chunkSize)) else { break }
                assembled += piece
            }
            webm = assembled
        }
        guard webm.count == length, let layout = WebMOpus.layout(webm) else {
            fallBackToAAC()
            return
        }
        completed = true
        perfLog.notice("downloaded \(self.videoId, privacy: .public) \(self.length) bytes (Opus) in \(Int(Date().timeIntervalSince(self.created) * 1000)) ms")
        let output = AudioCache.partialDirectory.appendingPathComponent("\(videoId)-\(UUID().uuidString).m4a")
        do {
            try WebMOpus.write(layout, from: webm, to: output)
            converted = .file(try FileHandle(forReadingFrom: output), length: layout.length)
            // Reading from the open handle goes on working after the move.
            AudioCache.adopt(output, videoId: videoId)
            resumeFileWaiters(with: AudioCache.replayCacheFile(for: videoId))
        } catch {
            // Full disk: keep it in memory for this play (a song is a few MB).
            try? FileManager.default.removeItem(at: output)
            converted = .memory(WebMOpus.data(layout, from: webm))
            resumeFileWaiters(with: nil)
        }
        try? partFile?.close()
        partFile = nil
        try? FileManager.default.removeItem(at: partURL)
        available = []
        inMemory = [:]
        serve()
    }

    /// Something about the Opus stream wasn't as expected: start over with the AAC one. The
    /// player's requests are still waiting, so it just takes a moment longer.
    private func fallBackToAAC() {
        opus = nil
        resumeFileWaiters(with: nil)
        generation += 1
        refreshesWithoutProgress = 0
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        failures = [:]
        try? partFile?.close()
        partFile = nil
        try? FileManager.default.removeItem(at: partURL)
        partURL = Self.newPartURL(videoId)
        available = []
        inMemory = [:]
        completed = false
        serve()
    }

    private func serveConverted() {
        guard let converted else {
            // Still downloading: answers come once the whole file is in and repackaged.
            pump(from: nil)
            return
        }
        let total = converted.length
        requests.removeAll { request in
            if let contentInfo = request.contentInformationRequest {
                contentInfo.contentType = AVFileType.m4a.rawValue
                contentInfo.contentLength = Int64(total)
                contentInfo.isByteRangeAccessSupported = true
            }
            guard let dataRequest = request.dataRequest else {
                request.finishLoading()
                return true
            }
            let end = dataRequest.requestsAllDataToEndOfResource
                ? total
                : min(total, Int(dataRequest.requestedOffset) + dataRequest.requestedLength)
            var offset = Int(dataRequest.currentOffset)
            while offset < end {
                let upTo = min(end, offset + chunkSize)
                let piece: Data?
                switch converted {
                case .file(let handle, _):
                    piece = (try? handle.seek(toOffset: UInt64(offset))).flatMap { _ in try? handle.read(upToCount: upTo - offset) }
                case .memory(let data):
                    piece = data.subdata(in: offset..<upTo)
                }
                guard let piece, piece.count == upTo - offset else {
                    request.finishLoading(with: InnerTubeError.noAudio)
                    return true
                }
                dataRequest.respond(with: piece)
                offset = upTo
            }
            request.finishLoading()
            return true
        }
    }
}
