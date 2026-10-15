import Foundation
import Observation

/// What you never want to hear: AI-generated music, explicit songs, artists and songs you've hidden,
/// and songs that turned out to be unplayable.
///
/// Hidden songs disappear from search, Home, shelves and radio, and are skipped in the queue. On an
/// album or playlist page they stay in place but dimmed, so the list
/// still matches the real thing. AI detection layers several signals, since YouTube has no single
/// reliable flag: your own marks, a shared list of known AI artists, tell-tale titles, and YouTube's
/// "Altered or synthetic content" disclosure, checked for songs about to play.
@MainActor
@Observable
final class ContentFilter {
    static let shared = ContentFilter()

    // MARK: Settings

    var hideAI = UserDefaults.standard.object(forKey: "filter.hideAI") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideAI, forKey: "filter.hideAI"); version += 1 }
    }
    var hideExplicit = UserDefaults.standard.bool(forKey: "filter.hideExplicit") {
        didSet { UserDefaults.standard.set(hideExplicit, forKey: "filter.hideExplicit"); version += 1 }
    }
    var hideUnavailable = UserDefaults.standard.object(forKey: "filter.hideUnavailable") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideUnavailable, forKey: "filter.hideUnavailable"); version += 1 }
    }
    /// Check YouTube's AI disclosure for songs before they play (one small request per song).
    var checkYouTubeLabels = UserDefaults.standard.object(forKey: "filter.checkLabels") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checkYouTubeLabels, forKey: "filter.checkLabels") }
    }
    /// A shared list of known AI artists: plain text, one channel id (UC…) or artist name per line
    /// (`#` starts a comment), or a JSON array of strings.
    var communityListURL = UserDefaults.standard.string(forKey: "filter.communityURL") ?? "" {
        didSet { UserDefaults.standard.set(communityListURL, forKey: "filter.communityURL") }
    }

    /// Bumped on every change, so lists that cache filtered results know to redo them.
    private(set) var version = 0

    // MARK: Lists

    struct Entry: Codable, Hashable, Identifiable {
        var id: String
        var name: String
    }

    private(set) var hiddenArtists: [Entry] = []
    private(set) var hiddenSongs: [Entry] = []
    private(set) var aiArtists: [Entry] = []
    private(set) var aiSongs: [Entry] = []
    private(set) var communityAI: Set<String> = []
    private(set) var communityUpdated: Date?
    /// YouTube's AI disclosure, by video id, for songs already checked.
    private var labelChecks: [String: Bool] = [:]
    private var checking: Set<String> = []
    /// Songs YouTube refused to play.
    private(set) var unavailable: Set<String> = []
    /// "Snooze": songs kept out of your listening until a date, by video id.
    private(set) var snoozed: [String: Date] = [:]

    private init() {
        hiddenArtists = Self.load("filter.hiddenArtists") ?? []
        hiddenSongs = Self.load("filter.hiddenSongs") ?? []
        aiArtists = Self.load("filter.aiArtists") ?? []
        aiSongs = Self.load("filter.aiSongs") ?? []
        communityAI = Set(Self.load("filter.communityAI") ?? [String]())
        communityUpdated = UserDefaults.standard.object(forKey: "filter.communityUpdated") as? Date
        labelChecks = Self.load("filter.labelChecks") ?? [:]
        unavailable = Set(Self.load("filter.unavailable") ?? [String]())
        snoozed = (Self.load("filter.snoozed") ?? [String: Date]()).filter { $0.value > Date() }
    }

    // MARK: Questions

    private static func key(_ artist: ArtistRef) -> String { artist.browseId ?? "name:\(artist.name.lowercased())" }

    private func matches(_ entries: [Entry], _ artist: ArtistRef) -> Bool {
        entries.contains { $0.id == Self.key(artist) || $0.name.caseInsensitiveCompare(artist.name) == .orderedSame }
    }

    /// Title patterns that give an AI track away (AI covers, Suno/Udio generations). Whole words
    /// only: "Studio" or "Thai music" must not match.
    private static let aiTitlePatterns: [NSRegularExpression] = [
        #"\bai[- ](cover|version|song|generated|remix|music|voice|vocals?)\b"#,
        #"\b(suno|udio)(\.ai| ai)?\b"#,
        #"[(\[]\s*ai\s*[)\]]"#,
        #"\|\s*ai\b"#,
        #"\b(made|generated|created) (with|by) (ai|suno|udio)\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    nonisolated(unsafe) private static var titleCache: [String: Bool] = [:]

    static func titleLooksAI(_ title: String) -> Bool {
        if let known = titleCache[title] { return known }
        let range = NSRange(title.startIndex..., in: title)
        let result = aiTitlePatterns.contains { $0.firstMatch(in: title, range: range) != nil }
        if titleCache.count > 20_000 { titleCache.removeAll() }
        titleCache[title] = result
        return result
    }

    func isAIArtist(_ artist: ArtistRef) -> Bool {
        matches(aiArtists, artist)
            || Self.titleLooksAI(artist.name)
            || communityAI.contains(Self.key(artist).lowercased())
            || communityAI.contains(artist.name.lowercased())
    }

    /// Why a song counts as AI, if it does.
    func aiReason(_ track: Track) -> String? {
        if track.isLocal { return nil }
        if aiSongs.contains(where: { $0.id == track.videoId }) { return String(localized: "You marked this as AI") }
        if let artist = track.artists.first(where: isAIArtist) { return String(localized: "\(artist.name) is listed as an AI artist") }
        if labelChecks[track.videoId] == true { return String(localized: "YouTube labels this as altered or synthetic content") }
        if Self.titleLooksAI(track.title) { return String(localized: "The title says it's AI-generated") }
        return nil
    }

    func isAI(_ track: Track) -> Bool { aiReason(track) != nil }

    func isHiddenByYou(_ track: Track) -> Bool {
        hiddenSongs.contains { $0.id == track.videoId } || track.artists.contains { matches(hiddenArtists, $0) } || isSnoozed(track)
    }

    func isSnoozed(_ track: Track) -> Bool {
        snoozed[track.videoId].map { $0 > Date() } ?? false
    }

    /// Keeps a song out of radio, shelves and the queue for 30 days — for songs you're tired of,
    /// not ones you never want to hear again.
    func snooze(_ track: Track) {
        snoozed[track.videoId] = Date().addingTimeInterval(30 * 86_400)
        Self.store(snoozed, "filter.snoozed")
        version += 1
        Router.shared.showToast(String(localized: "Snoozed for 30 days"), icon: "moon.zzz.fill") { [weak self] in self?.unsnooze(track) }
        PlayerController.shared.contentFilterChanged()
    }

    func unsnooze(_ track: Track) {
        snoozed[track.videoId] = nil
        Self.store(snoozed, "filter.snoozed")
        version += 1
    }

    /// Whether the song should be kept out of lists and the queue.
    func isHidden(_ track: Track) -> Bool {
        if isHiddenByYou(track) { return true }
        if hideExplicit, track.isExplicit == true { return true }
        if hideUnavailable, unavailable.contains(track.videoId) { return true }
        if hideAI, isAI(track) { return true }
        return false
    }

    /// Artist cards and pages of hidden or (with the filter on) AI artists.
    func isHidden(_ item: MediaItem) -> Bool {
        guard item.target.kind == .artist else { return false }
        let artist = ArtistRef(name: item.title, browseId: item.target.browseId)
        return matches(hiddenArtists, artist) || (hideAI && isAIArtist(artist))
    }

    func filter(_ tracks: [Track]) -> [Track] { tracks.filter { !isHidden($0) } }

    func filter(_ items: [ShelfItem]) -> [ShelfItem] {
        items.filter { item in
            switch item {
            case .track(let track): !isHidden(track)
            case .media(let media): !isHidden(media)
            }
        }
    }

    // MARK: Your marks

    func hide(_ track: Track) { hide([track]) }

    /// Hides songs with one toast, whose Undo brings them all back.
    func hide(_ tracks: [Track]) {
        let known = Set(hiddenSongs.map(\.id))
        var seen = Set<String>()
        let fresh = tracks.filter { !known.contains($0.videoId) && seen.insert($0.videoId).inserted }
        guard !fresh.isEmpty else { return }
        hiddenSongs.insert(contentsOf: fresh.map { Entry(id: $0.videoId, name: "\($0.title) — \($0.artistLine)") }, at: 0)
        save()
        let ids = Set(fresh.map(\.videoId))
        Router.shared.showToast(fresh.count == 1 ? String(localized: "Hidden — you won't hear this song") : String(localized: "Hidden \(fresh.count) songs"),
                                icon: "eye.slash.fill") { [weak self] in self?.unhide(songIds: ids) }
        PlayerController.shared.contentFilterChanged()
    }

    func unhide(songId: String) { unhide(songIds: [songId]) }

    func unhide(songIds: Set<String>) {
        hiddenSongs.removeAll { songIds.contains($0.id) }
        save()
    }

    func hide(artist: ArtistRef) {
        guard !matches(hiddenArtists, artist) else { return }
        hiddenArtists.insert(Entry(id: Self.key(artist), name: artist.name), at: 0)
        save()
        Router.shared.showToast(String(localized: "You won't hear \(artist.name)"), icon: "person.crop.circle.badge.xmark") { [weak self] in
            self?.unhide(artistId: Self.key(artist))
        }
        PlayerController.shared.contentFilterChanged()
    }

    func unhide(artistId: String) {
        hiddenArtists.removeAll { $0.id == artistId }
        save()
    }

    func isArtistHidden(_ artist: ArtistRef) -> Bool { matches(hiddenArtists, artist) }

    /// "This is AI": the song, and optionally its artist, count as AI from now on. Also tells YouTube
    /// you dislike it, so recommendations learn too.
    func markAI(_ track: Track, includingArtist: Bool) {
        if !aiSongs.contains(where: { $0.id == track.videoId }) {
            aiSongs.insert(Entry(id: track.videoId, name: "\(track.title) — \(track.artistLine)"), at: 0)
        }
        if includingArtist, let artist = track.artists.first, !matches(aiArtists, artist) {
            aiArtists.insert(Entry(id: Self.key(artist), name: artist.name), at: 0)
        }
        save()
        if AuthManager.shared.isSignedIn {
            Task { try? await MusicAPI.setLike(.dislike, videoId: track.videoId) }
        }
        let artistName = track.artists.first?.name ?? String(localized: "the artist")
        Router.shared.showToast(includingArtist ? String(localized: "Marked \(artistName) as AI") : String(localized: "Marked as AI"),
                                icon: "sparkles") { [weak self] in
            self?.unmarkAI(songId: track.videoId, artistId: includingArtist ? track.artists.first.map(Self.key) : nil)
        }
        PlayerController.shared.contentFilterChanged()
    }

    func markAI(artist: ArtistRef) {
        guard !matches(aiArtists, artist) else { return }
        aiArtists.insert(Entry(id: Self.key(artist), name: artist.name), at: 0)
        save()
        Router.shared.showToast(String(localized: "Marked \(artist.name) as AI"), icon: "sparkles") { [weak self] in
            self?.unmarkAI(songId: nil, artistId: Self.key(artist))
        }
        PlayerController.shared.contentFilterChanged()
    }

    func unmarkAI(songId: String?, artistId: String?) {
        if let songId { aiSongs.removeAll { $0.id == songId } }
        if let artistId { aiArtists.removeAll { $0.id == artistId } }
        save()
    }

    /// The player found a song it can't play.
    func markUnavailable(_ videoId: String) {
        guard unavailable.insert(videoId).inserted else { return }
        Self.store(Array(unavailable), "filter.unavailable")
        version += 1
    }

    func clearUnavailable() {
        unavailable = []
        Self.store([String](), "filter.unavailable")
        version += 1
    }

    // MARK: YouTube's AI disclosure

    /// Checks YouTube's disclosure for songs about to play; true when a check just flagged one.
    func checkLabels(_ tracks: [Track]) async -> Set<String> {
        guard checkYouTubeLabels else { return [] }
        let todo = tracks.filter { !$0.isLocal && labelChecks[$0.videoId] == nil && !checking.contains($0.videoId) }.prefix(6)
        guard !todo.isEmpty else { return [] }
        checking.formUnion(todo.map(\.videoId))
        var flagged: Set<String> = []
        await withTaskGroup(of: (String, Bool?).self) { group in
            for track in todo {
                group.addTask { (track.videoId, try? await MusicAPI.hasSyntheticLabel(videoId: track.videoId)) }
            }
            for await (videoId, labeled) in group {
                checking.remove(videoId)
                guard let labeled else { continue }
                labelChecks[videoId] = labeled
                if labeled { flagged.insert(videoId) }
            }
        }
        // Keep the cache from growing forever.
        if labelChecks.count > 5000 { labelChecks = Dictionary(uniqueKeysWithValues: labelChecks.filter(\.value).map { ($0.key, $0.value) }) }
        Self.store(labelChecks, "filter.labelChecks")
        if !flagged.isEmpty { version += 1 }
        return flagged
    }

    // MARK: Shared list

    /// Refreshes the shared AI-artist list (at most daily unless forced).
    func refreshCommunityList(force: Bool = false) async -> Bool {
        let address = communityListURL.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty, let url = URL(string: address), url.scheme == "https" else {
            if communityListURL.isEmpty, !communityAI.isEmpty {
                communityAI = []
                Self.store([String](), "filter.communityAI")
                version += 1
            }
            return false
        }
        if !force, let updated = communityUpdated, Date().timeIntervalSince(updated) < 86_400 { return true }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return false }
        let entries: [String]
        if let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            entries = array.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) }
        } else {
            entries = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map {
                String($0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            }
        }
        communityAI = Set(entries.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        communityUpdated = Date()
        Self.store(Array(communityAI), "filter.communityAI")
        UserDefaults.standard.set(communityUpdated, forKey: "filter.communityUpdated")
        version += 1
        PlayerController.shared.contentFilterChanged()
        return true
    }

    // MARK: Storage

    private func save() {
        Self.store(hiddenArtists, "filter.hiddenArtists")
        Self.store(hiddenSongs, "filter.hiddenSongs")
        Self.store(aiArtists, "filter.aiArtists")
        Self.store(aiSongs, "filter.aiSongs")
        version += 1
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
