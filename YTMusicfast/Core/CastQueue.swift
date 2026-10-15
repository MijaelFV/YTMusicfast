import Foundation

/// Synced lyrics as a WebVTT text track, shown on the TV as captions while casting.
enum CastLyrics {
    /// An empty track: what the device gets for a song without synced lyrics.
    static let empty = "WEBVTT\n"

    /// A cue per sung line, from its time to the next line's (at most `longest` seconds, so a line
    /// doesn't stay up through an instrumental break). Nil without synced lyrics.
    static func webVTT(_ lyrics: Lyrics?, duration: TimeInterval?, longest: TimeInterval = 10) -> String? {
        guard let lines = lyrics?.lines, !lines.isEmpty else { return nil }
        let end = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var text = "WEBVTT\n"
        var cues = 0
        for (index, line) in lines.enumerated() {
            let words = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty, line.time.isFinite, line.time >= 0 else { continue }
            var until = line.time + longest
            if index + 1 < lines.count { until = min(until, lines[index + 1].time) }
            if let end { until = min(until, end) }
            guard until - line.time >= 0.05 else { continue }
            cues += 1
            text += "\n\(cues)\n\(timestamp(line.time)) --> \(timestamp(until))\n\(escape(words))\n"
        }
        return cues > 0 ? text : nil
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, millis % 1000)
    }

    /// Cue text is markup: `&`, `<` and `>` must be written as entities, and a line can't hold
    /// "-->" (or a blank line, which ends the cue).
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// The device's queue while casting: the song playing and, after it, the next one, so songs
/// follow each other without a fresh load and the TV shows what's up next. The queue itself
/// stays in the app; this decides what to change on the device to match it.
enum CastQueueSync {
    /// An item on the device's queue: its id there and the address it plays.
    struct Item: Equatable, Sendable {
        var id: Int
        var contentId: String
    }

    struct Plan: Equatable {
        /// Items to take off the device's queue.
        var remove: [Int] = []
        /// Whether the next song has to be added (it isn't there, nor on its way).
        var insert = false
        var isEmpty: Bool { remove.isEmpty && !insert }
    }

    /// What to change so the device holds just the playing item and the next song's address
    /// (`next`, nil for none). Items played before, and a next song that's no longer next, go.
    /// `inserting`: the next song was sent and the device hasn't listed it yet.
    static func plan(items: [Item], currentItemId: Int?, next: String?, inserting: Bool) -> Plan {
        var plan = Plan()
        var nextThere = false
        for item in items where item.id != currentItemId {
            if let next, item.contentId == next, !nextThere {
                nextThere = true
            } else {
                plan.remove.append(item.id)
            }
        }
        plan.insert = next != nil && !nextThere && !inserting
        return plan
    }

    /// The device moved on by itself to the song at `videoId`: where that is in the app's queue
    /// (by video id, `queue`, with `current` the one that was playing). The next one is the
    /// usual answer; with Repeat All, the first after the last. Nil when it's not in the queue
    /// any more, so the app loads its own next song instead.
    static func indexAfterAdvance(queue: [String], current: Int, to videoId: String, repeatAll: Bool) -> Int? {
        if current + 1 < queue.count {
            if queue[current + 1] == videoId { return current + 1 }
            return queue.indices.dropFirst(current + 1).first { queue[$0] == videoId }
        }
        if repeatAll, queue.first == videoId { return 0 }
        return nil
    }

    /// The video id in an address `CastMediaServer` gave out (`…/cast/<secret>/<id>` for a
    /// song's sound, `…/cast/<secret>/v/<id>/index.m3u8` for a music video).
    static func videoId(fromContentId contentId: String) -> String? {
        guard let path = URL(string: contentId)?.path else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "cast" else { return nil }
        if parts.count == 5, parts[2] == "v" { return parts[3] }
        return parts.count == 3 ? parts[2] : nil
    }
}
