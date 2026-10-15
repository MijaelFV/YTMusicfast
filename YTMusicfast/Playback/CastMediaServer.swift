import Foundation
import Network
import os

private let mediaLog = Logger(subsystem: "dev.ytmusicfast", category: "Cast")

/// Serves the song being cast to the Cast device, over the local network, from this Mac:
/// downloads and replays from disk, local files, and everything else fetched from YouTube by the
/// Mac (YouTube's stream addresses are tied to whoever asked for them, so the TV can't use them
/// directly). Music videos go as HLS (see `CastVideo`). Runs only while casting; every address
/// carries a random secret.
@MainActor
final class CastMediaServer {
    static let shared = CastMediaServer()

    private var listener: NWListener?
    private var port: UInt16?
    private let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    /// The songs the receiver may ask for, by video id.
    private var tracks: [String: Track] = [:]
    private var streams: [String: StreamInfo] = [:]
    /// Music videos being cast (the playing one and the next), by video id.
    private var videos: [String: CastVideo] = [:]

    private init() {}

    /// Starts listening (if needed) and returns the address the receiver should load for a song.
    func url(for track: Track) async throws -> URL {
        try await start()
        guard let port, let host = PhoneRemote.localIPv4() else { throw URLError(.cannotConnectToHost) }
        tracks[track.videoId] = track
        if tracks.count > 20 { tracks = tracks.filter { $0.key == track.videoId } }
        let name = track.videoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? track.videoId
        return URL(string: "http://\(host):\(port)/cast/\(secret)/\(name)")!
    }

    /// The address of a music video as HLS, or nil when it can't be cast as one (then its sound
    /// is cast instead).
    func videoURL(for track: Track) async -> URL? {
        guard (try? await start()) != nil, let port, let host = PhoneRemote.localIPv4(), await video(for: track) != nil else { return nil }
        let name = track.videoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? track.videoId
        return URL(string: "http://\(host):\(port)/cast/\(secret)/v/\(name)/index.m3u8")
    }

    private func video(for track: Track) async -> CastVideo? {
        if let known = videos[track.videoId] { return known }
        guard let (audio, codecs) = await audioFragments(for: track),
              let video = await CastVideo.make(videoId: track.videoId, audio: audio, audioCodecs: codecs),
              listener != nil else { return nil }
        if videos.count >= 3 { videos = videos.filter { $0.key == CastController.shared.loadedVideoId } }
        videos[track.videoId] = video
        return video
    }

    /// A video's sound in fragments: the replay or download on this Mac (if it isn't Opus), or
    /// YouTube's AAC.
    private func audioFragments(for track: Track) async -> (CastFragments, String)? {
        if let file = AudioCache.cachedFile(for: track.videoId), !WebMOpus.isOpus(file) {
            let fragments = CastFragments(file: file)
            if await fragments.load() { return (fragments, "mp4a.40.2") }
        }
        let videoId = track.videoId
        var info = streams[videoId].flatMap { $0.isExpired ? nil : $0 }
        if info == nil { info = try? await ChainedStreamResolver.shared.resolve(videoId: videoId) }
        guard let info, info.mimeType.hasPrefix("audio/mp4") else { return nil }
        streams[videoId] = info
        let codecs = info.mimeType.range(of: "codecs=\"").flatMap { start in
            info.mimeType[start.upperBound...].split(separator: "\"").first.map(String.init)
        } ?? "mp4a.40.2"
        let fragments = CastFragments(remote: info.url, mimeType: "audio/mp4") {
            await CastMediaServer.shared.refreshStream(videoId)?.url
        }
        return (fragments, codecs)
    }

    /// Looks up the next song's stream ahead of time, so a skip while casting doesn't wait for
    /// YouTube. One request per song (a few for a music video), only while casting.
    func prepare(_ track: Track) async {
        guard listener != nil, track.localPath == nil else { return }
        if CastController.shared.castsVideo(track) {
            _ = await video(for: track)
            return
        }
        guard streams[track.videoId] == nil else { return }
        if let file = AudioCache.cachedFile(for: track.videoId), !WebMOpus.isOpus(file) { return }
        guard let info = try? await ChainedStreamResolver.shared.resolve(videoId: track.videoId) else { return }
        streams[track.videoId] = info
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        tracks = [:]
        streams = [:]
        videos = [:]
    }

    private func start() async throws {
        if listener != nil, port != nil { return }
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            Task { @MainActor in CastMediaServer.shared.accept(connection) }
        }
        self.listener = listener
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .main)
        }
        self.port = port
    }

    // MARK: Requests

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, done, error in
            Task { @MainActor in
                var buffer = buffer
                if let data { buffer += data }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    await CastMediaServer.shared.respond(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
                } else if done || error != nil || buffer.count > 65_536 {
                    connection.cancel()
                } else {
                    CastMediaServer.shared.receiveHead(connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(_ head: String, on connection: NWConnection) async {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { first, _ in first })
        // The receiver is a web page: it may check first that it's allowed to ask.
        if parts.first == "OPTIONS" {
            send(status: "204 No Content", headers: ["Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
                                                     "Access-Control-Allow-Headers": "Range, Content-Type"], body: Data(), on: connection)
            return
        }
        let path = parts.count > 1 ? String(parts[1]).split(separator: "/").map(String.init) : []
        if parts.count > 1, path.count == 5, path[0] == "cast", path[1] == secret, path[2] == "v" {
            await respondVideo(videoId: path[3].removingPercentEncoding ?? path[3], file: path[4], range: headers["range"],
                               head: parts[0] == "HEAD", on: connection)
            return
        }
        guard parts.count > 1, path.count == 3, path[0] == "cast", path[1] == secret,
              let videoId = path[2].removingPercentEncoding, let track = tracks[videoId] else {
            send(status: "404 Not Found", headers: [:], body: Data(), on: connection)
            return
        }
        guard let source = await source(for: track) else {
            send(status: "502 Bad Gateway", headers: [:], body: Data(), on: connection)
            return
        }
        let hasRange = headers["range"] != nil
        guard let range = ByteRange.parse(headers["range"], length: source.length, limit: .max) else {
            send(status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(source.length)"], body: Data(), on: connection)
            return
        }
        var responseHeaders = [
            "Content-Type": source.mimeType,
            "Accept-Ranges": "bytes",
            "Content-Length": "\(range.count)",
        ]
        if hasRange { responseHeaders["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(source.length)" }
        let head = Self.head(status: hasRange ? "206 Partial Content" : "200 OK", headers: responseHeaders)
        guard parts[0] != "HEAD" else {
            connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: head, completion: .contentProcessed { _ in })
        // The body follows in pieces as they're read or fetched; a receiver that seeks elsewhere
        // just drops this connection, which ends the loop.
        Task.detached(priority: .userInitiated) {
            var offset = range.lowerBound
            while offset <= range.upperBound {
                let end = min(range.upperBound, offset + (1 << 20) - 1)
                guard let piece = await source.read(offset...end, refresh: { await CastMediaServer.shared.refreshStream(videoId) }),
                      !piece.isEmpty, await Self.send(piece, on: connection) else { break }
                offset += piece.count
            }
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// A playlist, header or fragment of a music video (small enough to send in one go).
    private func respondVideo(videoId: String, file: String, range rangeHeader: String?, head: Bool, on connection: NWConnection) async {
        guard let video = videos[videoId] else {
            send(status: "404 Not Found", headers: [:], body: Data(), on: connection)
            return
        }
        guard let (data, mimeType) = await video.file(file) else {
            mediaLog.notice("video \(videoId, privacy: .public): \(file, privacy: .public) unavailable")
            send(status: "502 Bad Gateway", headers: [:], body: Data(), on: connection)
            return
        }
        guard let range = ByteRange.parse(rangeHeader, length: data.count, limit: .max) else {
            send(status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(data.count)"], body: Data(), on: connection)
            return
        }
        var headers = ["Content-Type": mimeType, "Accept-Ranges": "bytes"]
        let body = rangeHeader == nil ? data : data.subdata(in: range.lowerBound..<(range.upperBound + 1))
        if rangeHeader != nil { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(data.count)" }
        let status = rangeHeader == nil ? "200 OK" : "206 Partial Content"
        mediaLog.debug("video \(videoId, privacy: .public): \(file, privacy: .public) \(body.count) bytes")
        guard !head else {
            headers["Content-Length"] = "\(body.count)"
            connection.send(content: Self.head(status: status, headers: headers), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        send(status: status, headers: headers, body: body, on: connection)
    }

    private func refreshStream(_ videoId: String) async -> StreamInfo? {
        await ChainedStreamResolver.shared.invalidate(videoId)
        let fresh = try? await ChainedStreamResolver.shared.resolve(videoId: videoId)
        streams[videoId] = fresh
        return fresh
    }

    /// Where a song's bytes come from: a file on this Mac, or YouTube's stream.
    private func source(for track: Track) async -> CastSource? {
        if let path = track.localPath { return CastSource(file: URL(fileURLWithPath: path)) }
        // Opus in MP4 (this app's own repackaging, see WebMOpus) isn't a format Cast devices
        // promise to play: they get YouTube's AAC instead, and the file only when offline.
        let file = AudioCache.cachedFile(for: track.videoId)
        if let file, !WebMOpus.isOpus(file) { return CastSource(file: file) }
        if let info = streams[track.videoId], !info.isExpired { return CastSource(stream: info) }
        guard let info = try? await ChainedStreamResolver.shared.resolve(videoId: track.videoId) else {
            return file.flatMap(CastSource.init(file:))
        }
        streams[track.videoId] = info
        return CastSource(stream: info)
    }

    private func send(status: String, headers: [String: String], body: Data, on connection: NWConnection) {
        var headers = headers
        headers["Content-Length"] = "\(body.count)"
        connection.send(content: Self.head(status: status, headers: headers) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    nonisolated private static func head(status: String, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status)\r\n"
        // The Cast receiver is a web page: let it read the audio.
        var all = headers
        all["Access-Control-Allow-Origin"] = "*"
        all["Cache-Control"] = "no-store"
        all["Connection"] = "close"
        for (name, value) in all { text += "\(name): \(value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    nonisolated private static func send(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }
}

/// A music video for the Cast device, as HLS made from YouTube's separate picture (H.264 up to
/// 1080p, every size, so the device picks by its screen and connection) and sound (AAC). Cast
/// devices can't use YouTube's own playlists or fragments (YouTube doesn't let other web pages
/// read them), so this Mac relays them a fragment at a time as the device asks: a few Mbps over
/// the local network, only while a video is being cast.
final class CastVideo: @unchecked Sendable {
    private let master: String
    private let parts: [String: CastFragments]

    /// Nil when there's nothing a Cast device plays (no H.264, or no index to cut fragments by).
    static func make(videoId: String, audio: CastFragments, audioCodecs: String) async -> CastVideo? {
        guard let formats = try? await ChainedStreamResolver.shared.videoFormats(videoId: videoId) else { return nil }
        var bySize: [Int: VideoFormat] = [:]
        for format in formats where format.codecs.hasPrefix("avc1") && format.height <= 1080 {
            if let known = bySize[format.height], known.fps >= format.fps { continue }
            bySize[format.height] = format
        }
        // Tiny sizes only when there's nothing else (a TV would show them blurred).
        if bySize.keys.contains(where: { $0 >= 360 }) { bySize = bySize.filter { $0.key >= 360 } }
        guard !bySize.isEmpty else { return nil }
        let renditions = bySize.values.map { format in
            (format, CastFragments(remote: format.url, mimeType: "video/mp4") {
                // Addresses expire after a few hours: the same size again, freshly asked for.
                let fresh = try? await ChainedStreamResolver.shared.videoFormats(videoId: videoId)
                return fresh?.first { $0.height == format.height && $0.codecs == format.codecs }?.url
            })
        }
        // Every index at once (a few small reads), so the device's first requests don't wait.
        async let audioReady = audio.load()
        let loaded = await withTaskGroup(of: (VideoFormat, CastFragments)?.self) { group in
            for (format, part) in renditions { group.addTask { await part.load() ? (format, part) : nil } }
            var loaded: [(VideoFormat, CastFragments)] = []
            for await result in group { if let result { loaded.append(result) } }
            return loaded.sorted { $0.0.bitrate < $1.0.bitrate }
        }
        guard await audioReady, !loaded.isEmpty else { return nil }
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"",
        ]
        var parts = ["audio": audio]
        for (format, part) in loaded {
            lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(max(format.bitrate, 1) + 130_000),RESOLUTION=\(format.width)x\(format.height),"
                         + "CODECS=\"\(format.codecs),\(audioCodecs)\",FRAME-RATE=\(format.fps),AUDIO=\"audio\"")
            lines.append("\(format.height).m3u8")
            parts["\(format.height)"] = part
        }
        return CastVideo(master: lines.joined(separator: "\n") + "\n", parts: parts)
    }

    private init(master: String, parts: [String: CastFragments]) {
        self.master = master
        self.parts = parts
    }

    /// A file of the stream by its name: `index.m3u8` (every size), `<part>.m3u8`, `<part>-init.mp4`
    /// (the header) or `<part>-<offset>.m4s` (a fragment), where a part is `audio` or a height.
    func file(_ name: String) async -> (data: Data, mimeType: String)? {
        if name == "index.m3u8" { return (Data(master.utf8), "application/vnd.apple.mpegurl") }
        if name.hasSuffix(".m3u8") {
            let part = String(name.dropLast(5))
            guard let playlist = await parts[part]?.playlist(named: part) else { return nil }
            return (Data(playlist.utf8), "application/vnd.apple.mpegurl")
        }
        let stem = name.split(separator: ".").first.map(String.init) ?? ""
        guard let dash = stem.lastIndex(of: "-"), let part = parts[String(stem[..<dash])] else { return nil }
        let what = stem[stem.index(after: dash)...]
        if what == "init", name.hasSuffix(".mp4") { return await part.header().map { ($0, part.mimeType) } }
        guard name.hasSuffix(".m4s"), let offset = Int(what) else { return nil }
        return await part.fragment(at: offset).map { ($0, part.mimeType) }
    }
}

/// The bytes of one song, from a file or from YouTube in ranged pieces.
struct CastSource: Sendable {
    let length: Int
    let mimeType: String
    private let file: URL?
    private let stream: StreamInfo?

    init?(file: URL) {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else { return nil }
        length = size
        self.file = file
        stream = nil
        mimeType = switch file.pathExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "flac": "audio/flac"
        case "wav", "wave": "audio/wav"
        case "ogg", "oga": "audio/ogg"
        case "webm": "audio/webm"
        default: "audio/mp4"
        }
    }

    init(stream: StreamInfo) {
        length = stream.contentLength
        mimeType = stream.mimeType.hasPrefix("audio/webm") ? "audio/webm" : "audio/mp4"
        file = nil
        self.stream = stream
    }

    func read(_ range: ClosedRange<Int>, refresh: @Sendable () async -> StreamInfo?) async -> Data? {
        if let file {
            if range.lowerBound == 0 { FragmentedMP4.fixFile(file) }
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(range.lowerBound))
            return try? handle.read(upToCount: range.count)
        }
        guard let stream else { return nil }
        var data = await Self.fetch(stream, range)
        if data == nil, let fresh = await refresh() {
            // Stream addresses expire after a few hours: asked again with a fresh one.
            data = await Self.fetch(fresh, range)
        }
        if range.lowerBound == 0, var head = data {
            FragmentedMP4.fixHeaderDurations(&head)
            return head
        }
        return data
    }

    private static func fetch(_ stream: StreamInfo, _ range: ClosedRange<Int>) async -> Data? {
        guard var components = URLComponents(url: stream.url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "range", value: "\(range.lowerBound)-\(range.upperBound)")]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(InnerTube.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        return data
    }
}
