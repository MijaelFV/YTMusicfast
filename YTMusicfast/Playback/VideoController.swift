import AVFoundation
import Observation
import VideoToolbox
import os

/// Each step of loading a video, with timings (Console → subsystem dev.ytmusicfast, category Video).
let videoLog = Logger(subsystem: "dev.ytmusicfast", category: "Video")

/// YouTube Music's video mode: the music video plays in Now Playing and full screen.
///
/// Audio keeps coming from `PlayerController` (gapless, crossfade, EQ, normalization all still
/// apply); this plays the matching video-only stream muted and keeps it in step with the audio.
/// It only decodes while some view is showing it.
@MainActor
@Observable
final class VideoController {
    static let shared = VideoController()

    /// The Song/Video switch. On: music videos show instead of artwork, and songs offer their video.
    var videoMode = UserDefaults.standard.bool(forKey: "videoMode") {
        didSet {
            UserDefaults.standard.set(videoMode, forKey: "videoMode")
            refresh()
            if videoMode != oldValue { PlayerController.shared.versionModeChanged() }
        }
    }

    /// Video quality (YouTube's Quality menu): 0 is Auto — the size the view and connection allow —
    /// otherwise a fixed height (1080, 720…). Remembered.
    var quality = UserDefaults.standard.integer(forKey: "videoQuality") {
        didSet {
            guard quality != oldValue else { return }
            UserDefaults.standard.set(quality, forKey: "videoQuality")
            // The picture again at the new size, lined back up with the music.
            if let id = loadedVideoId { load(id) }
        }
    }

    /// Full screen: fill the screen instead of keeping thin bars (a 16:9 video on a 16:10 Mac
    /// screen loses about 5% at each side). Off by default, like YouTube; in the Video quality menu.
    var fillsScreen = UserDefaults.standard.bool(forKey: "videoFillsScreen") {
        didSet { UserDefaults.standard.set(fillsScreen, forKey: "videoFillsScreen") }
    }

    /// The sizes the playing video comes in (tallest first), for the Quality menu.
    private(set) var availableHeights: [Int] = []

    /// The height Auto is showing right now (0 while unknown).
    var playingHeight: Int { Int(player.currentItem?.presentationSize.height ?? 0) }

    /// The current video's picture is loaded, lined up with the music, and ready to fade in.
    private(set) var hasVideo = false
    private(set) var loading = false

    @ObservationIgnored let player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        return player
    }()

    @ObservationIgnored private var loadedVideoId: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The video being served as HLS, while loaded.
    @ObservationIgnored private var stream: VideoStream?
    @ObservationIgnored private var syncTimer: Timer?
    /// How many views are showing the video right now.
    @ObservationIgnored private var surfaces = 0

    private init() {}

    /// The playing song changed (called by the player).
    func trackChanged() {
        guard surfaces > 0 || loadedVideoId != nil else { return }
        refresh()
    }

    /// Whether the playing item is a music video (so there's something to show).
    var currentIsVideo: Bool { PlayerController.shared.current?.isVideo == true }

    func surfaceAppeared() {
        surfaces += 1
        refresh()
    }

    func surfaceDisappeared() {
        surfaces = max(0, surfaces - 1)
        guard surfaces == 0 else { return }
        // A moment's grace: a view being replaced by another (a page or panel changing) must not
        // throw away the loaded video.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if surfaces == 0 { stop() }
        }
    }

    /// Starts loading a video's picture before its sound has taken over (the Song/Video switch),
    /// so both are ready together.
    func prepare(videoId: String) {
        guard videoMode, surfaces > 0, loadedVideoId != videoId else { return }
        load(videoId)
    }

    private func refresh() {
        // Song → Video in progress: the song still plays while its video's sound loads, and the
        // picture prepared for it (see `prepare`) must not be thrown away meanwhile.
        if videoMode, surfaces > 0, PlayerController.shared.versionTarget == true, let loadedVideoId {
            videoLog.notice("refresh: keeping \(loadedVideoId, privacy: .public) while the switch finishes")
            return
        }
        guard videoMode, surfaces > 0, let track = PlayerController.shared.current, track.isVideo, !track.isLocal else {
            if loadedVideoId != nil {
                videoLog.notice("refresh: stop (videoMode \(self.videoMode), surfaces \(self.surfaces), video \(PlayerController.shared.current?.isVideo == true))")
            }
            stop()
            return
        }
        if track.videoId == loadedVideoId {
            if hasVideo { startSync() }
            return
        }
        load(track.videoId)
    }

    private func load(_ videoId: String) {
        videoLog.notice("load \(videoId, privacy: .public) (surfaces \(self.surfaces), quality \(self.quality))")
        loadTask?.cancel()
        syncTimer?.invalidate()
        hasVideo = false
        loading = true
        loadedVideoId = videoId
        // The old picture can fade out undisturbed: its fragments come straight from YouTube.
        closeStream()
        loadTask = Task {
            defer { if loadedVideoId == videoId { loading = false } }
            let started = Date()
            func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
            guard let formats = await formats(for: videoId), !Task.isCancelled, loadedVideoId == videoId else {
                videoLog.notice("load \(videoId, privacy: .public): no sizes / cancelled after \(ms()) ms")
                return
            }
            videoLog.notice("load \(videoId, privacy: .public): \(formats.count) sizes at \(ms()) ms")
            // Adaptive HLS (see VideoStream); the best plain H.264 file if that can't be set up.
            guard let address = await streamAddress(formats) else { return }
            guard !Task.isCancelled, loadedVideoId == videoId else { closeStream(); return }
            let item = AVPlayerItem(url: address)
            item.preferredForwardBufferDuration = 20
            if quality == 0 {
                // Auto: no bigger than it's shown, starting small so it appears quickly.
                item.preferredMaximumResolution = largestSurface
                Self.startSmall(item)
            }
            player.replaceCurrentItem(with: item)
            // Wait until it can show a frame, then line it up with the music before it fades in
            // (no flash of the video's first frame, no jump).
            while item.status == .unknown {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled || loadedVideoId != videoId { return }
            }
            videoLog.notice("load \(videoId, privacy: .public): item \(item.status == .readyToPlay ? "ready" : "failed", privacy: .public) at \(ms()) ms \(item.error?.localizedDescription ?? "", privacy: .public)")
            guard item.status == .readyToPlay else { return }
            if let length = PlayerController.shared.current?.duration, length > 0, PlayerController.shared.current?.videoId == videoId {
                item.forwardPlaybackEndTime = CMTime(seconds: length, preferredTimescale: 1000)
            }
            // Lined up with the music before it shows — but never waiting more than two seconds:
            // the sync below catches any difference while it plays.
            await Self.seek(player, to: PlayerController.shared.playbackPosition, timeout: 2)
            guard !Task.isCancelled, loadedVideoId == videoId else {
                videoLog.notice("load \(videoId, privacy: .public): cancelled after lining up at \(ms()) ms")
                return
            }
            videoLog.notice("load \(videoId, privacy: .public): showing at \(ms()) ms")
            hasVideo = true
            // Its sound may still be on the way (Song → Video): sync starts once it's playing.
            if PlayerController.shared.current?.videoId == videoId { startSync() }
        }
    }

    private func stop() {
        loadTask?.cancel()
        syncTimer?.invalidate()
        syncTimer = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        closeStream()
        availableHeights = []
        loadedVideoId = nil
        hasVideo = false
        loading = false
    }

    /// An exact seek that gives up waiting after `timeout` seconds (the seek itself goes on).
    private static func seek(_ player: AVPlayer, to seconds: TimeInterval, timeout: TimeInterval) async {
        final class Once: @unchecked Sendable {
            var continuation: CheckedContinuation<Void, Never>?
            func finish() { continuation?.resume(); continuation = nil }
        }
        let once = Once()
        await withCheckedContinuation { continuation in
            once.continuation = continuation
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { done in
                if !done { videoLog.notice("seek to \(seconds) s didn't finish") }
                DispatchQueue.main.async { once.finish() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if once.continuation != nil { videoLog.notice("seek to \(seconds) s still waiting after \(timeout) s: showing anyway") }
                once.finish()
            }
        }
    }

    /// Starts at a modest size so the first frame shows quickly, then lets the player step up to
    /// what the view and connection allow (YouTube does the same).
    static func startSmall(_ item: AVPlayerItem) {
        item.preferredPeakBitRate = 2_500_000
        Task { @MainActor [weak item] in
            for _ in 0..<200 {
                guard let item else { return }
                if item.status != .unknown { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .seconds(3))
            item?.preferredPeakBitRate = 0
        }
    }

    /// The last video's sizes, so changing quality doesn't ask YouTube again.
    @ObservationIgnored private var knownFormats: (videoId: String, formats: [VideoFormat])?

    private func formats(for videoId: String) async -> [VideoFormat]? {
        if let knownFormats, knownFormats.videoId == videoId { return knownFormats.formats }
        guard let formats = try? await ChainedStreamResolver.shared.videoFormats(videoId: videoId) else { return nil }
        knownFormats = (videoId, formats)
        return formats
    }

    /// The master playlist of every size (or just the chosen one), served locally; or the best
    /// H.264 file as it is.
    private func streamAddress(_ formats: [VideoFormat]) async -> URL? {
        availableHeights = VideoStream.heights(formats)
        if let stream = await VideoStream.make(formats, height: quality == 0 ? nil : quality),
           let master = try? await HLSServer.shared.playlistURL(for: stream) {
            closeStream()
            self.stream = stream
            return master
        }
        return formats.filter { !$0.isAV1 && $0.height <= 1080 }.max { $0.height < $1.height }?.url
    }

    /// The pixel size of each view showing the video, so the picture is never fetched bigger than it's shown.
    @ObservationIgnored private var surfaceSizes: [ObjectIdentifier: CGSize] = [:]
    private var largestSurface: CGSize {
        surfaceSizes.values.reduce(.zero) { CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height)) }
    }

    /// A view showing the video changed size (in pixels; `.zero` when it goes away).
    func surface(_ view: AnyObject, isShownAt pixels: CGSize) {
        surfaceSizes[ObjectIdentifier(view)] = pixels == .zero ? nil : pixels
        if quality == 0 { player.currentItem?.preferredMaximumResolution = largestSurface }
    }

    private func closeStream() {
        stream?.close()
        stream = nil
    }

    /// Play, pause or a seek happened: follow at once instead of at the next check.
    func syncNow() {
        guard hasVideo, loadedVideoId == PlayerController.shared.current?.videoId else { return }
        sync(force: true)
    }

    /// Keeps the picture on the music. Checked twice a second while showing.
    private func startSync() {
        syncTimer?.invalidate()
        sync(force: true)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync(force: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    /// Small drift is corrected by running the video a touch faster or slower (invisible); only a
    /// big one (a seek, a stall) jumps it.
    private func sync(force: Bool) {
        guard hasVideo, player.currentItem != nil else { return }
        let audio = PlayerController.shared
        let target = audio.playbackPosition
        let baseRate = audio.isPlaying && !audio.isBuffering ? Float(audio.playbackRate) : 0
        let drift = player.currentTime().seconds - target  // positive: the video is ahead
        guard drift.isFinite else { return }
        if baseRate == 0 {
            if player.rate != 0 { player.pause() }
            if abs(drift) > 0.05 {
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return
        }
        if abs(drift) > (force ? 0.25 : 0.8) {
            // Land a little ahead: the seek itself takes a moment.
            player.seek(to: CMTime(seconds: target + 0.08, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.player.rate = baseRate }
            }
            return
        }
        let nudge = abs(drift) > 0.04 ? Float(max(-0.05, min(0.05, -drift * 0.5))) : 0
        // Streamed video (HLS) plays at most 2×; past that a drift is caught by the jump above.
        let rate = min(2, baseRate * (1 + nudge))
        if abs(player.rate - rate) > 0.001 { player.rate = rate }
    }
}

private final class Finished: @unchecked Sendable { var done: Bool? }

extension VideoController {
    /// For `ytmusicfast diagnose`: loads a video's picture the way the video view does, inside
    /// the app, with its own muted player (nothing on screen), and reports each step.
    static func diagnose(videoId: String, height: Int? = nil, jumpTo: TimeInterval? = nil, noOutput: Bool = false) async -> String {
        var lines: [String] = []
        let started = Date()
        func elapsed() -> String { String(format: "%.2fs", Date().timeIntervalSince(started)) }
        guard let formats = try? await ChainedStreamResolver.shared.videoFormats(videoId: videoId) else { return "Video: no link from YouTube" }
        let sizes = formats.map { "\($0.height)p\($0.isAV1 ? " AV1" : "")" }
        lines.append("Video sizes ✓ \(Array(Set(sizes)).sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }.joined(separator: ", ")) (\(elapsed())); AV1 hardware: \(VideoStream.decodesAV1 ? "yes" : "no")")
        guard let stream = await VideoStream.make(formats, height: height), let address = try? await HLSServer.shared.playlistURL(for: stream) else {
            return (lines + ["Adaptive stream ✗"]).joined(separator: "\n")
        }
        defer { stream.close() }
        lines.append("Adaptive stream ✓ (\(elapsed()))")
        let item = AVPlayerItem(url: address)
        if height == nil {
            // As the player page would show it (about 1200×680 points on a Retina screen).
            item.preferredMaximumResolution = CGSize(width: 2400, height: 1360)
            startSmall(item)
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        // `--no-output`: as the app was before the fix, with nowhere to draw.
        if !noOutput { item.add(output) }
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        // As the app's video player: paused until it's lined up (unless asked to play first).
        player.automaticallyWaitsToMinimizeStalling = true
        if jumpTo == nil { player.play() }
        for _ in 0..<200 where item.status == .unknown { try? await Task.sleep(for: .milliseconds(50)) }
        switch item.status {
        case .readyToPlay:
            lines.append("Player ready ✓ (\(elapsed())), length \(Int(item.duration.seconds)) s")
            // As in the app: the picture jumps to where the music already is.
            if let at = jumpTo {
                let finished = Finished()
                player.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { done in
                    finished.done = done
                }
                for _ in 0..<80 where finished.done == nil { try? await Task.sleep(for: .milliseconds(50)) }
                lines.append("Jump to \(Int(at)) s while paused: \(finished.done.map { $0 ? "✓" : "✗ cancelled" } ?? "✗ still waiting after 4 s") (\(elapsed()))")
                player.play()
            }
        case .failed: lines.append("Player failed ✗ \(item.error.map { ($0 as NSError).code.description + " " + $0.localizedDescription } ?? "")")
        default: lines.append("Player not ready after 10 s ✗")
        }
        var frames = 0
        var firstFrame: String?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            if output.hasNewPixelBuffer(forItemTime: player.currentTime()) {
                _ = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil)
                frames += 1
                if firstFrame == nil { firstFrame = elapsed() }
            }
        }
        lines.append(frames > 0 ? "Frames ✓ first at \(firstFrame ?? "?") (\(frames) in 4 s)" : "Frames ✗ none in 4 s")
        if let access = item.accessLog()?.events.last {
            lines.append("Playing size: \(Int(item.presentationSize.width))×\(Int(item.presentationSize.height)), \(Int(access.indicatedBitrate / 1000)) kbps, switches \(item.accessLog()?.events.count ?? 0)")
        }
        if let event = item.errorLog()?.events.last { lines.append("Error log: \(event.errorStatusCode) \(event.errorComment ?? "")") }
        player.pause()
        player.replaceCurrentItem(with: nil)
        return lines.joined(separator: "\n")
    }
}

/// Finds a song's music video, or a music video's song (YouTube Music's Song/Video switch).
/// Remembered, and asked once even when a prefetch and a click want it at the same time.
@MainActor
enum VersionLookup {
    private static var found: [String: Track?] = [:]
    private static var running: [String: Task<Track?, Never>] = [:]

    static func video(for track: Track) async -> Track? {
        await lookup("v" + track.videoId) { await MusicAPI.musicVideo(for: track) }
    }

    static func song(for video: Track) async -> Track? {
        await lookup("s" + video.videoId) { await MusicAPI.songVersion(for: video) }
    }

    private static func lookup(_ key: String, _ find: @escaping @MainActor () async -> Track?) async -> Track? {
        if let known = found[key] { return known }
        if let task = running[key] { return await task.value }
        let task = Task { await find() }
        running[key] = task
        let result = await task.value
        running[key] = nil
        if found.count > 200 { found.removeAll() }
        found[key] = .some(result)
        return result
    }

    /// Looks up the other version ahead of a click (while the Song/Video switch is on screen).
    static func prefetch(_ track: Track) {
        guard !track.isLocal else { return }
        let key = (track.isVideo ? "s" : "v") + track.videoId
        guard found[key] == nil, running[key] == nil else { return }
        Task { _ = track.isVideo ? await song(for: track) : await video(for: track) }
    }
}

/// A music video's picture as adaptive HLS, like YouTube's own player: every size YouTube
/// offers, listed in one master playlist, and AVFoundation picks — by the size it's shown at
/// (`preferredMaximumResolution`) and by how fast the connection is — switching up and down as
/// those change. Played from its plain address it would download one whole file first; as HLS
/// it fetches only what's on screen. The fragments come straight from YouTube (each its own
/// `&range=` slice); only the playlists and the corrected headers are served locally.
final class VideoStream: HLSSource, @unchecked Sendable {
    private let renditions: [VideoRendition]
    private let master: String
    var onRelease: (() -> Void)?
    var contentLength: Int { 0 }

    /// Hardware that decodes AV1 (Apple silicon from M3) gets YouTube's 1440p and 4K too.
    static let decodesAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    /// The sizes to offer: H.264 up to 1080p (the best frame rate of each), and with AV1 decoding,
    /// AV1 above that. Nil if there's nothing playable.
    /// One format per height: H.264 up to 1080p (the best frame rate of each), and with AV1
    /// decoding, AV1 above that.
    static func playable(_ formats: [VideoFormat]) -> [Int: VideoFormat] {
        var bySize: [Int: VideoFormat] = [:]
        for format in formats where format.isAV1 ? (decodesAV1 && format.height > 1080) : format.height <= 1080 {
            if let known = bySize[format.height], known.fps >= format.fps { continue }
            bySize[format.height] = format
        }
        return bySize
    }

    static func heights(_ formats: [VideoFormat]) -> [Int] { playable(formats).keys.sorted(by: >) }

    /// `height`: a fixed quality (the nearest size at or below it); nil for Auto.
    @MainActor
    static func make(_ formats: [VideoFormat], height: Int? = nil) async -> VideoStream? {
        var bySize = playable(formats)
        if let height, let chosen = bySize.keys.filter({ $0 <= height }).max() ?? bySize.keys.min() {
            bySize = [chosen: bySize[chosen]!]
        }
        guard !bySize.isEmpty else { return nil }
        // Listed first is where playback starts: 720p (or the nearest below) shows quickly and
        // looks right at most sizes; AVFoundation moves up or down from there.
        let sorted = bySize.values.sorted { $0.bitrate < $1.bitrate }
        let start = sorted.last { $0.height <= 720 } ?? sorted[0]
        let ordered = [start] + sorted.filter { $0 != start }
        var renditions: [VideoRendition] = []
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for format in ordered {
            let rendition = VideoRendition(format)
            guard let url = try? await HLSServer.shared.playlistURL(for: rendition) else { continue }
            renditions.append(rendition)
            lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(max(format.bitrate, 1)),RESOLUTION=\(format.width)x\(format.height),CODECS=\"\(format.codecs)\",FRAME-RATE=\(format.fps)")
            lines.append(url.absoluteString)
        }
        guard !renditions.isEmpty else { return nil }
        return VideoStream(renditions: renditions, master: lines.joined(separator: "\n") + "\n")
    }

    private init(renditions: [VideoRendition], master: String) {
        self.renditions = renditions
        self.master = master
    }

    func playlist() async -> String? { master }
    func bytes(_ range: ClosedRange<Int>) async -> Data? { nil }

    /// Done with: the server forgets it and its sizes.
    func close() {
        renditions.forEach { $0.close() }
        onRelease?()
        onRelease = nil
    }
}

/// One size of the video, as an HLS media playlist made from its fragment index — which is read
/// only when AVFoundation first asks for this size.
final class VideoRendition: HLSSource, @unchecked Sendable {
    private let format: VideoFormat
    private let lock = NSLock()
    private var header = Data()
    private var index: FragmentedMP4.Index?
    private var loading: Task<Bool, Never>?
    var onRelease: (() -> Void)?
    var contentLength: Int { lock.withLock { header.count } }

    private static let session = URLSession(configuration: .ephemeral)

    init(_ format: VideoFormat) {
        self.format = format
    }

    func close() {
        onRelease?()
        onRelease = nil
    }

    func playlist() async -> String? {
        guard await load(), let index = lock.withLock({ self.index }) else { return nil }
        let url = format.url
        return FragmentedMP4.playlist(for: index, mediaName: "media.mp4") { segment in
            Self.address(url, segment.offset...(segment.offset + segment.size - 1)).absoluteString
        }
    }

    func bytes(_ range: ClosedRange<Int>) async -> Data? {
        guard await load() else { return nil }
        return lock.withLock { range.upperBound < header.count ? header.subdata(in: range.lowerBound..<(range.upperBound + 1)) : nil }
    }

    /// Reads the header and index once (64 KB covers hours; a longer index gets a bigger look).
    private func load() async -> Bool {
        if lock.withLock({ index != nil }) { return true }
        let task: Task<Bool, Never> = lock.withLock {
            if let loading { return loading }
            let task = Task { [format] () -> Bool in
                for size in [65_536, 1_048_576] {
                    guard let head = try? await Self.fetch(format.url, 0...(size - 1)) else { return false }
                    if let found = FragmentedMP4.index(in: head) {
                        var header = head.prefix(found.header.upperBound)
                        FragmentedMP4.fixHeaderDurations(&header)
                        self.lock.withLock {
                            self.header = Data(header)
                            self.index = found
                        }
                        return true
                    }
                    if head.count < size { return false }
                }
                return false
            }
            loading = task
            return task
        }
        let loaded = await task.value
        if !loaded { lock.withLock { loading = nil } }
        return loaded
    }

    private static func address(_ url: URL, _ range: ClosedRange<Int>) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "range", value: "\(range.lowerBound)-\(range.upperBound)")]
        return components.url ?? url
    }

    private static func fetch(_ url: URL, _ range: ClosedRange<Int>) async throws -> Data {
        var request = URLRequest(url: address(url, range), timeoutInterval: 15)
        request.setValue(InnerTube.safariUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}
