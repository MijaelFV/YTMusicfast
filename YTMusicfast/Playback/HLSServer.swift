import Foundation
import Network

/// Something HLSServer serves: a playlist and the bytes it points to.
protocol HLSSource: AnyObject, Sendable {
    func playlist() async -> String?
    func bytes(_ range: ClosedRange<Int>) async -> Data?
    var contentLength: Int { get }
    /// Set by the server; the source calls it once it's done with.
    var onRelease: (() -> Void)? { get set }
}

/// Serves long recordings and music videos to AVFoundation as HLS, from this Mac only (127.0.0.1).
///
/// AVFoundation reads a plain fragmented MP4 end to end before playing — fine for a song, but a
/// podcast or a 12-hour stream would download hundreds of MB first. As HLS (a playlist of the
/// file's own fragments, from its index) it fetches only what it plays. AVFoundation lets an app
/// hand it HLS playlists directly but insists on fetching the audio over HTTP, hence this server.
/// It runs only while one is loaded; every address carries a random secret.
@MainActor
final class HLSServer {
    static let shared = HLSServer()

    private var listener: NWListener?
    private var port: UInt16?
    private let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var sources: [String: any HLSSource] = [:]

    private init() {}

    /// The playlist address for a source whose index is loaded.
    func playlistURL(for source: any HLSSource) async throws -> URL {
        try await start()
        guard let port else { throw URLError(.cannotConnectToHost) }
        let key = UUID().uuidString.lowercased()
        sources[key] = source
        source.onRelease = { [key] in Task { @MainActor in HLSServer.shared.release(key) } }
        return URL(string: "http://127.0.0.1:\(port)/\(secret)/\(key)/index.m3u8")!
    }

    private func release(_ key: String) {
        sources[key] = nil
        if sources.isEmpty {
            listener?.cancel()
            listener = nil
            port = nil
        }
    }

    private func start() async throws {
        if listener != nil, port != nil { return }
        let parameters = NWParameters.tcp
        // Only this Mac can connect.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            Task { @MainActor in HLSServer.shared.accept(connection) }
        }
        self.listener = listener
        port = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .main)
        }
    }

    /// Runs its first job only (the listener reports states on the main queue, one at a time).
    private final class Once: @unchecked Sendable {
        private var done = false
        func run(_ job: () -> Void) {
            guard !done else { return }
            done = true
            job()
        }
    }

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
                    let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    let rest = buffer[end.upperBound...]
                    await HLSServer.shared.respond(head, on: connection)
                    // Keep-alive: AVFoundation asks for fragment after fragment on one connection.
                    HLSServer.shared.receiveHead(connection, buffer: Data(rest))
                } else if done || error != nil || buffer.count > 65_536 {
                    connection.cancel()
                } else {
                    HLSServer.shared.receiveHead(connection, buffer: buffer)
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
        let path = parts.count > 1 ? parts[1].split(separator: "/").map(String.init) : []
        guard path.count == 3, path[0] == secret, let source = sources[path[1]] else {
            await send(status: "404 Not Found", headers: [:], body: Data(), on: connection)
            return
        }
        let isHead = parts.first == "HEAD"
        switch path[2] {
        case "index.m3u8":
            guard let playlist = await source.playlist() else {
                await send(status: "404 Not Found", headers: [:], body: Data(), on: connection)
                return
            }
            await send(status: "200 OK", headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                       body: isHead ? Data() : Data(playlist.utf8), on: connection)
        case "media.mp4":
            let length = source.contentLength
            guard let range = ByteRange.parse(headers["range"], length: length, limit: 8 << 20) else {
                await send(status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(length)"], body: Data(), on: connection)
                return
            }
            var responseHeaders = ["Content-Type": "video/mp4", "Accept-Ranges": "bytes"]
            responseHeaders["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(length)"
            if isHead {
                responseHeaders["Content-Length"] = "\(range.count)"
                await send(status: "206 Partial Content", headers: responseHeaders, body: Data(), on: connection, setLength: false)
                return
            }
            guard let data = await source.bytes(range) else {
                await send(status: "503 Service Unavailable", headers: [:], body: Data(), on: connection)
                return
            }
            await send(status: "206 Partial Content", headers: responseHeaders, body: data, on: connection)
        default:
            await send(status: "404 Not Found", headers: [:], body: Data(), on: connection)
        }
    }

    private func send(status: String, headers: [String: String], body: Data, on connection: NWConnection, setLength: Bool = true) async {
        var text = "HTTP/1.1 \(status)\r\n"
        var all = headers
        if setLength { all["Content-Length"] = "\(body.count)" }
        all["Cache-Control"] = "no-store"
        for (name, value) in all { text += "\(name): \(value)\r\n" }
        let payload = Data((text + "\r\n").utf8) + body
        await withCheckedContinuation { continuation in
            connection.send(content: payload, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}
