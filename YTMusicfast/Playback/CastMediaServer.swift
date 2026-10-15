import Foundation
import Network

/// Serves the song being cast to the Cast device, over the local network, from this Mac:
/// downloads and replays from disk, local files, and everything else fetched from YouTube by the
/// Mac (YouTube's stream addresses are tied to whoever asked for them, so the TV can't use them
/// directly). Runs only while casting; every address carries a random secret.
@MainActor
final class CastMediaServer {
    static let shared = CastMediaServer()

    private var listener: NWListener?
    private var port: UInt16?
    private let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    /// The songs the receiver may ask for, by video id.
    private var tracks: [String: Track] = [:]
    private var streams: [String: StreamInfo] = [:]

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

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        tracks = [:]
        streams = [:]
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
        let path = parts.count > 1 ? String(parts[1]).split(separator: "/").map(String.init) : []
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
