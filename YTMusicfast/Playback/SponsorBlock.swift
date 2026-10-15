import CryptoKit
import Foundation

/// SponsorBlock's "non-music section" segments: the skits, talking and long silent intros that
/// music videos often have around the song. Looked up by a 4-character hash prefix, so the
/// service never learns which video is playing.
enum SponsorBlock {
    struct Segment: Hashable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
    }

    private static let cache = SegmentCache()

    static func segments(for videoId: String) async -> [Segment] {
        if let cached = await cache.get(videoId) { return cached }
        let prefix = SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(4)
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(prefix)")!
        components.queryItems = [URLQueryItem(name: "categories", value: #"["music_offtopic"]"#),
                                 URLQueryItem(name: "actionTypes", value: #"["skip"]"#)]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return [] }
        // 404 means no segments for any video with this prefix.
        var found: [Segment] = []
        if (response as? HTTPURLResponse)?.statusCode == 200,
           let videos = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let video = videos.first(where: { $0["videoID"] as? String == videoId }),
           let segments = video["segments"] as? [[String: Any]] {
            found = segments.compactMap { segment in
                guard let range = segment["segment"] as? [Double], range.count == 2, range[1] - range[0] >= 1 else { return nil }
                return Segment(start: range[0], end: range[1])
            }
            .sorted { $0.start < $1.start }
        }
        await cache.set(videoId, found)
        return found
    }
}

private actor SegmentCache {
    private var storage: [String: [SponsorBlock.Segment]] = [:]

    func get(_ videoId: String) -> [SponsorBlock.Segment]? { storage[videoId] }

    func set(_ videoId: String, _ segments: [SponsorBlock.Segment]) {
        if storage.count > 300 { storage.removeAll() }
        storage[videoId] = segments
    }
}
