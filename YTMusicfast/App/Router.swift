import Observation
import SwiftUI

/// Where the main panel is.
enum Route: Hashable {
    case home
    case search
    case lyrics
    case page(BrowseTarget)
    /// "Show all" for a shelf YouTube has no page for: its items in a grid.
    case shelf(Shelf)
    /// Music folders on this Mac.
    case localFiles
    /// Your top songs and artists, from listening on this Mac.
    case stats
    /// A radio's songs, before playing them ("Go to radio").
    case radio(RadioSeed)
    /// YouTube Music's player page: the cover or music video, big, in the middle column.
    case nowPlaying
}

/// App-wide navigation and panel state, with browser-style back/forward history.
@MainActor
@Observable
final class Router {
    static let shared = Router()

    private(set) var route: Route = .home
    private var backStack: [Route] = []
    private var forwardStack: [Route] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Text in the top bar's search field (typing only suggests; see `search`).
    var searchQuery = ""
    /// What the Search page shows results for: set by Enter, a suggestion or a recent search
    /// (no search on every keystroke). Empty: Browse.
    private(set) var submittedQuery = ""
    /// Incremented to ask the search field to take focus.
    var searchFocusRequest = 0

    enum RightPanel: String { case nowPlaying, queue, devices }
    /// Right-hand panel; nil hides it.
    var rightPanel: RightPanel? = RightPanel(rawValue: UserDefaults.standard.string(forKey: "rightPanel") ?? "nowPlaying") {
        didSet { UserDefaults.standard.set(rightPanel?.rawValue ?? "hidden", forKey: "rightPanel") }
    }
    var libraryCollapsed = UserDefaults.standard.bool(forKey: "libraryCollapsed") {
        didSet { UserDefaults.standard.set(libraryCollapsed, forKey: "libraryCollapsed") }
    }

    /// The full screen player, in a window of its own over the whole screen.
    var showFullPlayer = false {
        didSet { if showFullPlayer != oldValue { FullPlayerWindow.shared.setVisible(showFullPlayer) } }
    }
    var showSignIn = false
    /// Tooltip currently shown by the window's tooltip layer.
    var tooltip: TooltipRequest?
    /// Songs waiting for the "Add to playlist" sheet.
    var addToPlaylist: TrackBatch?
    /// Song whose YouTube Music credits are showing.
    var creditsTrack: Track?
    var showShortcuts = false
    /// An add that hit songs already in the playlist, waiting for "Add anyway" / "Don't add".
    var pendingDuplicate: PendingDuplicate?
    /// Folder being renamed in Your Library.
    var renamingFolder: LocalLibrary.Folder?

    struct PendingDuplicate: Identifiable {
        let id = UUID()
        var videoIds: [String]
        var playlistId: String
        var playlistTitle: String
    }

    /// Adds songs to a playlist, asking first if any are already in it ("Already added").
    func add(videoIds: [String], toPlaylist playlistId: String, title: String, onAdded: (() -> Void)? = nil) {
        guard AuthManager.shared.isSignedIn else { showSignIn = true; return }
        Task {
            do {
                switch try await MusicAPI.add(videoIds: videoIds, toPlaylist: playlistId) {
                case .added:
                    showToast(videoIds.count == 1 ? String(localized: "Added to \(title)") : String(localized: "Added \(videoIds.count) songs to \(title)"))
                    onAdded?()
                case .duplicates:
                    pendingDuplicate = PendingDuplicate(videoIds: videoIds, playlistId: playlistId, playlistTitle: title)
                }
            } catch {
                showToast(String(localized: "Couldn't add to \(title)"), icon: "exclamationmark.triangle.fill")
            }
        }
    }

    func addDuplicatesAnyway(_ pending: PendingDuplicate) {
        Task {
            do {
                try await MusicAPI.add(videoIds: pending.videoIds, toPlaylist: pending.playlistId, allowDuplicates: true)
                showToast(String(localized: "Added to \(pending.playlistTitle)"))
            } catch {
                showToast(String(localized: "Couldn't add to \(pending.playlistTitle)"), icon: "exclamationmark.triangle.fill")
            }
        }
    }

    /// Opens "Add to playlist" for songs, or sign-in first.
    func addToPlaylist(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if AuthManager.shared.isSignedIn { addToPlaylist = TrackBatch(tracks: tracks) } else { showSignIn = true }
    }

    // MARK: Navigation

    func navigate(_ destination: Route) {
        showFullPlayer = false
        guard destination != route else { return }
        rememberScroll()
        backStack.append(route)
        if backStack.count > 50 { backStack.removeFirst() }
        forwardStack.removeAll()
        // A new visit starts at the top, even of a page that's also further back in history.
        restoreOffset = nil
        route = destination
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        rememberScroll()
        forwardStack.append(route)
        restoreOffset = scrollOffsets[previous]
        route = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        rememberScroll()
        backStack.append(route)
        restoreOffset = scrollOffsets[next]
        route = next
    }

    // MARK: Scroll position (Back and Forward return to where you were)

    /// How far each page in the history was scrolled when you left it.
    @ObservationIgnored private var scrollOffsets: [Route: CGFloat] = [:]
    /// Reads the main page's scroll offset; set by the page's `ScrollRestorer`.
    @ObservationIgnored var readScrollOffset: (() -> CGFloat?)?
    /// Where the page Back / Forward is opening should scroll to (taken once, by that page).
    @ObservationIgnored private var restoreOffset: CGFloat?

    func takeRestoreOffset() -> CGFloat? {
        defer { restoreOffset = nil }
        return restoreOffset
    }

    private func rememberScroll() {
        scrollOffsets[route] = readScrollOffset?()
        readScrollOffset = nil
        // Only pages still reachable with Back / Forward.
        if scrollOffsets.count > 60 {
            scrollOffsets = scrollOffsets.filter { backStack.contains($0.key) || forwardStack.contains($0.key) || $0.key == route }
        }
    }

    func open(_ target: BrowseTarget) {
        // App-made lists (the Stats page) aren't YouTube pages.
        navigate(target.browseId == StatsView.target.browseId ? .stats : .page(target))
    }

    func open(artist: ArtistRef) {
        guard let id = artist.browseId else { return }
        open(BrowseTarget(browseId: id, kind: .artist, title: artist.name))
    }

    func open(album: AlbumRef) {
        guard let id = album.browseId else { return }
        open(BrowseTarget(browseId: id, kind: .album, title: album.name))
    }

    func focusSearch() {
        searchFocusRequest += 1
    }

    /// Runs a search and shows its results (an empty query shows Browse).
    func search(_ query: String) {
        searchQuery = query
        submittedQuery = query.trimmingCharacters(in: .whitespaces)
        navigate(.search)
    }

    func toggleNowPlayingPage() {
        if showFullPlayer {
            showFullPlayer = false
            navigate(.nowPlaying)
        } else if route == .nowPlaying {
            goBack()
        } else {
            navigate(.nowPlaying)
        }
    }

    func toggleLyrics() {
        // The full screen player shows them beside the cover.
        if showFullPlayer { TVPlayerState.shared.toggleLyrics(); return }
        if route == .lyrics { goBack() } else { navigate(.lyrics) }
    }

    func togglePanel(_ panel: RightPanel) {
        if showFullPlayer, panel == .queue { TVPlayerState.shared.toggleUpNext(); return }
        rightPanel = rightPanel == panel ? nil : panel
    }

    // MARK: Toasts

    struct Toast: Equatable {
        let id = UUID()
        var message: String
        var icon: String
        /// "Undo" on toasts for changes that are easy to regret.
        var undo: (() -> Void)?

        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }
    private(set) var toast: Toast?

    func showToast(_ message: String, icon: String = "checkmark.circle.fill", undo: (() -> Void)? = nil) {
        let next = Toast(message: message, icon: icon, undo: undo)
        toast = next
        Task {
            // Longer when there's something to undo.
            try? await Task.sleep(for: .seconds(undo == nil ? 2.2 : 5))
            if toast?.id == next.id { toast = nil }
        }
    }

    /// Runs the toast's undo and dismisses it.
    func undoToast() {
        guard let toast else { return }
        self.toast = nil
        toast.undo?()
    }

    // MARK: Well-known pages

    static let likedSongs = BrowseTarget(browseId: "VLLM", kind: .playlist, title: String(localized: "Liked Music"))
    static let history = BrowseTarget(browseId: "FEmusic_history", kind: .other, title: String(localized: "Recently played"))
    static let explore = BrowseTarget(browseId: "FEmusic_explore", kind: .other, title: String(localized: "Explore"))
    static let charts = BrowseTarget(browseId: "FEmusic_charts", kind: .other, title: String(localized: "Charts"))
    static let moods = BrowseTarget(browseId: "FEmusic_moods_and_genres", kind: .other, title: String(localized: "Browse all"))
    /// Every song in your library (from saved albums, likes and uploads).
    static let librarySongs = BrowseTarget(browseId: "FEmusic_liked_videos", kind: .other, title: String(localized: "Songs"))
    static let uploads = BrowseTarget(browseId: "FEmusic_library_privately_owned_tracks", kind: .other, title: String(localized: "Uploads"))
    static let episodesForLater = BrowseTarget(browseId: "VLSE", kind: .playlist, title: String(localized: "Episodes for Later"))
}

/// Several songs acted on together (multi-selection, a whole queue).
struct TrackBatch: Identifiable {
    let id = UUID()
    var tracks: [Track]
}

enum Format {
    static func time(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    enum Noun { case song, folder, play, item, artist }

    /// "1 song", "12 songs" — each language's plural forms come from the string catalog.
    static func count(_ n: Int, _ noun: Noun) -> String {
        switch noun {
        case .song: String(localized: "\(n) songs")
        case .folder: String(localized: "\(n) folders")
        case .play: String(localized: "\(n) plays")
        case .item: String(localized: "\(n) items")
        case .artist: String(localized: "\(n) artists")
        }
    }

    /// "1 hr, 20 min" in the Mac's language.
    static func longDuration(_ seconds: TimeInterval) -> String {
        durationFormatter.string(from: (seconds / 60).rounded(.down) * 60) ?? ""
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()

    static var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: String(localized: "Good morning")
        case 12..<18: String(localized: "Good afternoon")
        default: String(localized: "Good evening")
        }
    }
}
