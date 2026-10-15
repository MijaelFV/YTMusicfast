import Foundation
import Observation

/// Your listening, kept on this Mac: every song you listen to for 30 seconds or more (the usual
/// rule for a stream). Feeds the Stats page and Home's "On repeat".
@MainActor
@Observable
final class ListeningStats {
    static let shared = ListeningStats()

    typealias Play = Listen

    private(set) var plays: [Play] = []

    /// Plays are appended, never edited, so a cap keeps the file small (≈ 4 MB).
    private static let maxPlays = 15_000
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("YTMusicfast", isDirectory: true).appendingPathComponent("plays.json")
    }
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        guard !Bench.enabled, let data = try? Data(contentsOf: Self.fileURL) else { return }
        plays = (try? JSONDecoder().decode([Play].self, from: data)) ?? []
    }

    func record(_ track: Track, at date: Date, seconds: TimeInterval) {
        // Keep what identifies the song; drop playlist slots, history tokens and the like.
        var slim = Track(videoId: track.videoId, title: track.title, artists: track.artists, album: track.album,
                         duration: track.duration, thumbnail: track.thumbnail, isVideo: track.isVideo)
        slim.isExplicit = track.isExplicit
        slim.localPath = track.localPath
        plays.append(Play(track: slim, date: date, seconds: seconds))
        if plays.count > Self.maxPlays { plays.removeFirst(plays.count - Self.maxPlays) }
        version += 1
        scheduleSave()
    }

    func clear() {
        plays = []
        version += 1
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = plays
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            let url = await ListeningStats.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Summaries

    enum Range: String, CaseIterable, Identifiable {
        case month, halfYear, year, allTime
        var id: String { rawValue }

        var title: String {
            switch self {
            case .month: String(localized: "Last 4 weeks")
            case .halfYear: String(localized: "Last 6 months")
            case .year: String(localized: "Last 12 months")
            case .allTime: String(localized: "All time")
            }
        }

        var start: Date {
            let now = Date()
            switch self {
            case .month: return now.addingTimeInterval(-28 * 86_400)
            case .halfYear: return Calendar.current.date(byAdding: .month, value: -6, to: now) ?? now
            case .year: return Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
            case .allTime: return .distantPast
            }
        }
    }

    typealias TopTrack = ListeningSummary.TopTrack
    typealias TopArtist = ListeningSummary.TopArtist
    typealias Summary = ListeningSummary

    /// Views re-render often (Home's tint follows the pointer), so summaries are worked out once
    /// per change to the plays, not per render.
    @ObservationIgnored private var summaries: [Range: (version: Int, summary: Summary)] = [:]
    @ObservationIgnored private var version = 0

    func summary(for range: Range) -> Summary {
        _ = plays.count  // observe changes
        if let cached = summaries[range], cached.version == version { return cached.summary }
        let summary = ListeningSummary(plays, since: range.start)
        summaries[range] = (version, summary)
        return summary
    }
}

/// Measures how long each queue entry is actually heard (not just started) and records finished
/// listens in the stats.
@MainActor
final class PlayTracker {
    static let shared = PlayTracker()

    private var entryId: UUID?
    private var track: Track?
    private var startedAt = Date()
    private var listened: TimeInterval = 0

    /// Called from the player's clock with the media time that passed while playing.
    func advance(entry: UUID, track: Track, by delta: TimeInterval, privateSession: Bool) {
        if entry != entryId { finish(); begin(entry: entry, track: track) }
        guard !privateSession else { return }
        listened += delta
    }

    /// The current listen is over (song changed, repeated or the app is quitting).
    func finish() {
        if let track, listened >= 30 {
            ListeningStats.shared.record(track, at: startedAt, seconds: listened)
        }
        entryId = nil
        track = nil
        listened = 0
    }

    private func begin(entry: UUID, track: Track) {
        entryId = entry
        self.track = track
        startedAt = Date()
        listened = 0
    }
}
