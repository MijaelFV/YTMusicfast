import Foundation

/// Tells YouTube Music what you listened to, the way its web player does, so your phone and the
/// website know too: a "playback" ping once a song has played a few seconds (it goes into
/// History, and so Listen again), then "watchtime" pings with the stretches of it you heard
/// (recommendations and Recap go by how much of a song you listen to). A few small requests a
/// song: at 10 seconds, every 40 seconds after, on pause, and when it ends or you move on.
@MainActor
final class WatchTime {
    static let shared = WatchTime()

    private struct Play {
        let entry: UUID
        let videoId: String
        /// The client's playback id: the same for every ping of one play.
        let cpn = WatchTime.makeCPN()
        let started = Date()
        var watchtimeURL: URL?
        var asked = false
        /// Heard so far, and since the last ping.
        var heard: TimeInterval = 0
        var pending: TimeInterval = 0
        var pings = 0
        /// Stretches heard since the last ping (song seconds), the last one still growing.
        var segments: [(start: Double, end: Double)] = []
        var position: Double = 0
    }

    private var play: Play?

    /// Signed in, history on (Settings), not in a private session. Checked before every ping, so
    /// turning one off stops them at once.
    private static var allowed: Bool {
        let player = PlayerController.shared
        return player.syncHistory && !player.privateSession && AuthManager.shared.isSignedIn
    }

    /// From the player's clock: `from`…`to` of the song was just heard, uninterrupted.
    func heard(entry: UUID, track: Track, from: Double, to: Double) {
        if play?.entry != entry || play?.videoId != track.videoId {
            finish()
            guard Self.allowed, !track.isLocal else { return }
            play = Play(entry: entry, videoId: track.videoId)
        }
        guard var current = play else { return }
        if let last = current.segments.last, abs(last.end - from) < 0.05 {
            current.segments[current.segments.count - 1].end = to
        } else {
            current.segments.append((from, to))
        }
        current.position = to
        current.heard += to - from
        current.pending += to - from
        play = current
        if current.heard >= 5, !current.asked { start() }
        if current.heard >= 10, current.pings == 0 || current.pending >= 40 { send(state: "playing") }
    }

    /// Paused: what was heard so far goes in now (the next stretch starts afresh).
    func paused() {
        guard play != nil else { return }
        send(state: "paused")
    }

    /// The play is over (another song, the end, a repeat, quitting): the last stretch, marked final.
    func finish() {
        guard play != nil else { return }
        send(state: "paused", final: true)
        play = nil
    }

    /// History: the playback ping, and the watchtime address for the pings after it.
    private func start() {
        guard let current = play, Self.allowed else { return }
        play?.asked = true
        let videoId = current.videoId, cpn = current.cpn, entry = current.entry
        let fallback = PlayerController.shared.statsURLs[videoId]
        Task {
            let urls = await MusicAPI.statsURLs(videoId: videoId)
            if let playback = urls.playback ?? fallback {
                Task.detached(priority: .utility) { await MusicAPI.ping(playback, [("cpn", cpn)]) }
            }
            // The song may have moved on meanwhile; its last pings then go without an address.
            if play?.entry == entry, play?.videoId == videoId { play?.watchtimeURL = urls.watchtime }
        }
    }

    private func send(state: String, final: Bool = false) {
        guard var current = play, Self.allowed, let base = current.watchtimeURL, !current.segments.isEmpty else { return }
        func seconds(_ value: Double) -> String { String(format: "%.3f", value) }
        var parameters: [(String, String)] = [
            ("cpn", current.cpn),
            ("cmt", seconds(current.position)),
            ("st", current.segments.map { seconds($0.start) }.joined(separator: ",")),
            ("et", current.segments.map { seconds($0.end) }.joined(separator: ",")),
            ("rt", seconds(Date().timeIntervalSince(current.started))),
            ("state", state),
            ("el", "detailpage"),
        ]
        if final { parameters.append(("final", "1")) }
        current.pings += 1
        current.pending = 0
        current.segments = []
        play = current
        Task.detached(priority: .utility) { await MusicAPI.ping(base, parameters) }
    }

    private nonisolated static func makeCPN() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }
}
