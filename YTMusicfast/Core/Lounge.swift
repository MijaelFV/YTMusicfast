import Foundation

/// YouTube's "link with TV" remote protocol (the lounge): the one phone remotes use to drive the
/// YouTube app on a TV. No API key or account: the TV's YouTube app (launched over Cast) gives its
/// screen id, the screen id gets a lounge token, and the token binds a remote session that sends
/// commands and hears back what the TV plays.
///
/// Unofficial, so everything here is tolerant: unknown events are kept as plain fields, junk is
/// skipped. This file only encodes and decodes; `YouTubeLounge` does the networking.
enum Lounge {
    static let base = URL(string: "https://www.youtube.com/api/lounge")!
    /// The YouTube app on Cast devices, and the Cast namespace it answers its screen id on.
    static let castAppId = "233637DE"
    static let mdxNamespace = "urn:x-cast:com.google.youtube.mdx"
    /// How this app shows up on the TV ("YT Musicfast connected").
    static let remoteName = "YT Musicfast"

    // MARK: Events

    /// One event from the TV, e.g. `[12, ["onStateChange", {"state": "1", "currentTime": "4.2"}]]`.
    /// An object's values are kept as strings (the lounge sends numbers as strings anyway); other
    /// arguments by position ("0", "1", …), e.g. `["c", "<SID>", "", 8]` → `["0": "<SID>", …]`.
    struct Event: Equatable, Sendable {
        var id: Int
        var name: String
        var fields: [String: String] = [:]

        init(id: Int, name: String, fields: [String: String] = [:]) {
            self.id = id
            self.name = name
            self.fields = fields
        }

        init?(_ element: Any) {
            guard let pair = element as? [Any], pair.count >= 2, let id = Lounge.int(pair[0]),
                  let body = pair[1] as? [Any], let name = body.first as? String else { return nil }
            self.id = id
            self.name = name
            let arguments = body.dropFirst()
            if arguments.count == 1, let object = arguments.first as? [String: Any] {
                for (key, value) in object { fields[key] = Lounge.string(value) }
            } else {
                for (index, value) in arguments.enumerated() { fields["\(index)"] = Lounge.string(value) }
            }
        }
    }

    /// Splits the server's stream into events. It comes in chunks, each a line with a length and
    /// then a JSON array of events: `"58\n[[0,[\"c\",\"SID\",\"\",8]],[1,[\"S\",\"gsession\"]]]"`.
    /// The length counts UTF-16 units, which bytes don't tell; the array's own brackets do, so
    /// each chunk ends where its outermost array closes.
    struct ChunkReader {
        private var digits = 0
        private var body = Data()
        private var depth = 0
        private var inString = false
        private var escaped = false

        mutating func append(_ data: Data) -> [Event] {
            var events: [Event] = []
            for byte in data { events += append(byte) }
            return events
        }

        mutating func append(_ byte: UInt8) -> [Event] {
            if depth == 0 {
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    digits += 1
                case UInt8(ascii: "["):
                    // A body starts once a length was read (anything else is junk between chunks).
                    guard digits > 0 else { return [] }
                    body = Data([byte])
                    depth = 1
                    inString = false
                    escaped = false
                case UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: " "):
                    break
                default:
                    digits = 0
                }
                return []
            }
            body.append(byte)
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                return []
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "]"): depth -= 1
            default: break
            }
            guard depth == 0 else { return [] }
            digits = 0
            defer { body = Data() }
            guard let array = (try? JSONSerialization.jsonObject(with: body)) as? [Any] else { return [] }
            return array.compactMap(Event.init)
        }
    }

    // MARK: What the TV plays

    /// The TV's player, from `onStateChange` or `nowPlaying`.
    struct Playback: Equatable, Sendable {
        enum State: Equatable, Sendable {
            case unstarted, ended, playing, paused, buffering, cued, advertisement
            case unknown(Int)

            init(_ code: Int) {
                switch code {
                case -1: self = .unstarted
                case 0: self = .ended
                case 1: self = .playing
                case 2: self = .paused
                case 3: self = .buffering
                case 5: self = .cued
                case 1081: self = .advertisement
                default: self = .unknown(code)
                }
            }
        }

        /// Only `nowPlaying` says which video (an empty `nowPlaying` means nothing is loaded).
        var videoId: String?
        var state: State?
        var currentTime: TimeInterval?
        var duration: TimeInterval?

        init(videoId: String? = nil, state: State? = nil, currentTime: TimeInterval? = nil, duration: TimeInterval? = nil) {
            self.videoId = videoId
            self.state = state
            self.currentTime = currentTime
            self.duration = duration
        }

        init?(_ event: Event) {
            guard event.name == "onStateChange" || event.name == "nowPlaying" else { return nil }
            videoId = event.fields["videoId"].flatMap { $0.isEmpty ? nil : $0 }
            state = event.fields["state"].flatMap(Int.init).map(State.init)
            currentTime = event.fields["currentTime"].flatMap(Double.init).flatMap { $0.isFinite ? max(0, $0) : nil }
            duration = event.fields["duration"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
    }

    // MARK: Commands

    enum Command: Equatable, Sendable {
        /// Plays `videoIds[index]` from `time`, with the rest of the list after it (so the TV goes
        /// on by itself while this Mac sleeps).
        case setPlaylist(videoIds: [String], index: Int, time: TimeInterval)
        case play, pause, next, previous, getNowPlaying
        case seek(TimeInterval)
        /// Puts a video right after the one playing, or takes one out of the list.
        case insertVideo(String), removeVideo(String)
        /// 0…100.
        case setVolume(Int)
        /// The TV's own "up next" after the list ends.
        case setAutoplay(Bool)

        var name: String {
            switch self {
            case .setPlaylist: "setPlaylist"
            case .play: "play"
            case .pause: "pause"
            case .next: "next"
            case .previous: "previous"
            case .getNowPlaying: "getNowPlaying"
            case .seek: "seekTo"
            case .setVolume: "setVolume"
            case .setAutoplay: "setAutoplayMode"
            case .insertVideo: "insertVideo"
            case .removeVideo: "removeVideo"
            }
        }

        var parameters: [(String, String)] {
            switch self {
            case let .setPlaylist(videoIds, index, time):
                let index = videoIds.indices.contains(index) ? index : 0
                return [("videoId", videoIds.isEmpty ? "" : videoIds[index]), ("videoIds", videoIds.joined(separator: ",")),
                        ("currentIndex", "\(index)"), ("currentTime", Lounge.seconds(time)), ("listId", ""), ("audioOnly", "false")]
            case let .seek(time): return [("newTime", Lounge.seconds(time))]
            case let .insertVideo(id), let .removeVideo(id): return [("videoId", id)]
            case let .setVolume(volume): return [("volume", "\(min(100, max(0, volume)))")]
            case let .setAutoplay(on): return [("autoplayMode", on ? "ENABLED" : "DISABLED")]
            default: return []
            }
        }
    }

    /// The TV went on to `video` by itself (its list ran on, maybe while this Mac slept): how many
    /// songs the queue here moves on to match it. Nil when it isn't the list as sent (`sent[0]` was
    /// playing then), or the queue here has changed since: then it's not the queue's next.
    static func songsAhead(to video: String, sent: [String], upNext: [String]) -> Int? {
        guard sent.count > 1, let at = sent.dropFirst().firstIndex(of: video) else { return nil }
        let passed = Array(sent[1...at])
        guard Array(upNext.prefix(passed.count)) == passed else { return nil }
        return passed.count
    }

    /// The form body that sends one command: `count=1&ofs=N&req0__sc=seekTo&req0_newTime=42`.
    /// `offset` counts the commands sent in this session.
    static func commandForm(_ command: Command, offset: Int) -> [(String, String)] {
        [("count", "1"), ("ofs", "\(offset)"), ("req0__sc", command.name)] + command.parameters.map { ("req0_\($0.0)", $0.1) }
    }

    /// The form that binds a remote session, as a phone remote does.
    static func bindForm(remoteId: String) -> [(String, String)] {
        [("device", "REMOTE_CONTROL"), ("id", remoteId), ("name", remoteName), ("mdx-version", "3"),
         ("pairing_type", "cast"), ("app", "ytmusicfast")]
    }

    static func form(_ pairs: [(String, String)]) -> Data { Data(formString(pairs).utf8) }

    /// `a=1&b=x%2Cy`, for a form body or a query.
    static func formString(_ pairs: [(String, String)]) -> String {
        // Only these go unescaped (a "+" or "," in a value must be escaped).
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._*")
        return pairs.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    // MARK: Pairing

    /// The session ids a bind answers with: `["c", SID, …]` and `["S", gsessionid]`.
    static func session(in events: [Event]) -> (sid: String, gsessionId: String)? {
        guard let sid = events.first(where: { $0.name == "c" })?.fields["0"], !sid.isEmpty,
              let gsession = events.first(where: { $0.name == "S" })?.fields["0"], !gsession.isEmpty else { return nil }
        return (sid, gsession)
    }

    /// The screen id in the TV app's answer to `getMdxSessionStatus` on `mdxNamespace`:
    /// `{"type": "mdxSessionStatus", "data": {"screenId": "…", "deviceId": "…"}}`.
    static func screenId(inMdxMessage json: [String: Any]) -> String? {
        guard json["type"] as? String == "mdxSessionStatus", let data = json["data"] as? [String: Any],
              let id = data["screenId"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// The lounge token in `get_lounge_token_batch`'s answer:
    /// `{"screens": [{"screenId": "…", "loungeToken": "…", "expiration": <ms since 1970>}]}`.
    static func loungeToken(in data: Data, screenId: String) -> (token: String, expires: Date?)? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let screens = json["screens"] as? [[String: Any]],
              let screen = screens.first(where: { $0["screenId"] as? String == screenId }) ?? screens.first,
              let token = screen["loungeToken"] as? String, !token.isEmpty else { return nil }
        let expires = int(screen["expiration"] as Any).map { Date(timeIntervalSince1970: Double($0) / 1000) }
        return (token, expires)
    }

    // MARK: Helpers

    static func seconds(_ time: TimeInterval) -> String {
        let time = time.isFinite ? max(0, time) : 0
        return String(format: "%.3f", time)
    }

    private static func int(_ value: Any) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func string(_ value: Any) -> String {
        switch value {
        case let value as String: return value
        case let value as NSNumber:
            // JSON booleans come back as NSNumber too.
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "true" : "false" }
            return value.stringValue
        case is NSNull: return ""
        default:
            guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
