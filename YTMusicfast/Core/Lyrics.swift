import Foundation

struct LyricLine: Identifiable, Hashable, Sendable {
    var id: Int
    var time: TimeInterval
    var text: String
}

struct Lyrics: Sendable {
    /// Time-synced lines (empty when only plain text is available).
    var lines: [LyricLine] = []
    var plain: String?
    var source: String

    var isSynced: Bool { !lines.isEmpty }

    func lineIndex(at time: TimeInterval) -> Int? {
        guard isSynced else { return nil }
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }
}

/// Synced lyrics from LRCLIB (open, community-run), falling back to YouTube's plain lyrics.
actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: Lyrics?] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    func lyrics(for track: Track, duration: TimeInterval) async -> Lyrics? {
        if let cached = cache[track.videoId] { return cached }
        var result = await lrclib(track: track, duration: duration)
        if result == nil, let yt = await MusicAPI.youtubeLyrics(videoId: track.videoId) {
            result = Lyrics(plain: yt.text, source: yt.source ?? "YouTube Music")
        }
        cache[track.videoId] = result
        return result
    }

    private func lrclib(track: Track, duration: TimeInterval) async -> Lyrics? {
        let title = Self.clean(track.title)
        let artist = track.artists.first?.name ?? ""
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album = track.album?.name { exact.queryItems?.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { exact.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }

        if let json = await fetch(exact.url!), let lyrics = Self.lyrics(from: json) { return lyrics }

        // Fuzzy fallback: search and take the closest duration match.
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        guard let results = await fetch(search.url!)?.array, !results.isEmpty else { return nil }
        let ranked = results.sorted {
            abs(($0["duration"].double ?? 0) - duration) < abs(($1["duration"].double ?? 0) - duration)
        }
        for candidate in ranked.prefix(3) where duration <= 0 || abs((candidate["duration"].double ?? 0) - duration) < 8 {
            if let lyrics = Self.lyrics(from: candidate) { return lyrics }
        }
        return nil
    }

    private func fetch(_ url: URL) async -> JSON? {
        var request = URLRequest(url: url)
        request.setValue("YTMusicfast/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSON(data: data)
    }

    private static func lyrics(from json: JSON) -> Lyrics? {
        if json["instrumental"].bool == true { return Lyrics(plain: "♪ Instrumental ♪", source: "LRCLIB") }
        if let synced = json["syncedLyrics"].string, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return Lyrics(lines: lines, plain: json["plainLyrics"].string, source: "LRCLIB") }
        }
        if let plain = json["plainLyrics"].string, !plain.isEmpty { return Lyrics(plain: plain, source: "LRCLIB") }
        return nil
    }

    static func parseLRC(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            let matches = pattern.matches(in: line, range: range)
            guard let last = matches.last, let textRange = Range(NSRange(location: last.range.upperBound, length: range.length - last.range.upperBound), in: line) else { continue }
            let lyric = line[textRange].trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let m = Range(match.range(at: 1), in: line), let s = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[m]), let seconds = Double(line[s]) else { continue }
                lines.append(LyricLine(id: 0, time: minutes * 60 + seconds, text: lyric))
            }
        }
        return lines.sorted { $0.time < $1.time }.enumerated().map { LyricLine(id: $0, time: $1.time, text: $1.text) }
    }

    /// Strips YouTube-style decorations that LRCLIB titles don't have.
    static func clean(_ title: String) -> String {
        var t = title
        for pattern in [#"\s*[\(\[](official|lyric|audio|video|visualizer|remaster|remastered|feat\.|ft\.|en vivo|live)[^\)\]]*[\)\]]"#,
                        #"\s*-\s*(remaster(ed)?|live|en vivo).*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
