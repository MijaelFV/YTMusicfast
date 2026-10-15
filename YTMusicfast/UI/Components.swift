import SwiftUI

// MARK: - Menus

/// A playlist page you can edit: lets song menus and drags remove and reorder its songs.
struct PlaylistEditing {
    var remove: ([Track]) -> Void
    /// Nil while the list is sorted or filtered: positions then aren't the playlist's.
    var move: ((Track, Int) -> Void)?
    /// The menu item ("Remove from this Playlist", "Remove from Listening History").
    var removeTitle = String(localized: "Remove from this Playlist")
    var canRemove: (Track) -> Bool = { $0.setVideoId != nil }
    /// ⌘V: adds songs (by video id) to the end of your playlist. Nil where songs can't be added.
    var add: (([String]) -> Void)?
    /// Songs dragged in from elsewhere (another list, the queue, the player bar), dropped before
    /// the row at an index. Only while positions are the playlist's (unsorted, unfiltered).
    var insert: (([String], Int) -> Void)?
}

private struct PlaylistEditingKey: EnvironmentKey {
    static let defaultValue: PlaylistEditing? = nil
}

extension EnvironmentValues {
    var playlistEditing: PlaylistEditing? {
        get { self[PlaylistEditingKey.self] }
        set { self[PlaylistEditingKey.self] = newValue }
    }
}

/// Your playlists, for the menus' "Add to playlist ▸": loaded with Your Library, so the menu opens
/// instantly. Just ids and titles.
@MainActor
enum PlaylistTargets {
    private(set) static var options: [PlaylistOption] = []

    static func refresh() async {
        guard AuthManager.shared.isSignedIn else { options = []; return }
        // Any song works for asking which playlists you can add to.
        let probe = LocalLibrary.shared.recentTracks.first { !$0.isLocal }?.videoId ?? "dQw4w9WgXcQ"
        if let found = try? await MusicAPI.editablePlaylists(for: probe) { options = found }
    }

    /// "Add to playlist ▸": a new playlist, your playlists, and the full searchable list.
    static func submenu(for tracks: [Track]) -> MenuEntry {
        let router = Router.shared
        let ids = tracks.map(\.videoId)
        var entries: [MenuEntry] = [
            .action(String(localized: "Find a playlist…"), systemImage: "magnifyingglass") { router.addToPlaylist(tracks) },
            .action(String(localized: "New playlist"), systemImage: "plus") {
                guard AuthManager.shared.isSignedIn else { router.showSignIn = true; return }
                Task {
                    let title = tracks.count == 1 ? tracks[0].title : String(localized: "New Playlist")
                    if let id = try? await MusicAPI.createPlaylist(title: title, videoIds: ids) {
                        RemoteLibraryCache.needsReload += 1
                        router.showToast(String(localized: "Added to \(title)"))
                        router.open(BrowseTarget(browseId: "VL\(id)", kind: .playlist, title: title))
                    } else {
                        router.showToast(String(localized: "Couldn't create playlist"), icon: "exclamationmark.triangle.fill")
                    }
                }
            },
        ]
        if !options.isEmpty { entries.append(.divider) }
        entries += options.prefix(20).map { option in
            .action(option.title, systemImage: "music.note.list") {
                router.add(videoIds: ids, toPlaylist: option.playlistId, title: option.title)
            }
        }
        return .submenu(String(localized: "Add to playlist"), systemImage: "plus", entries)
    }
}

/// Sleep timer choices (the song menu's "Sleep timer ▸" and the player bar's moon).
@MainActor
enum SleepTimerEntries {
    static func make() -> [MenuEntry] {
        let player = PlayerController.shared
        var entries: [MenuEntry] = [5, 15, 30, 45, 60, 90].map { minutes in
            .action(String(localized: "\(minutes) minutes"), systemImage: "moon") { player.setSleepTimer(minutes: minutes) }
        }
        entries.append(.choice(String(localized: "End of song"), systemImage: "moon.haze", selected: player.sleepTimer == .endOfTrack) {
            player.setSleepTimerEndOfTrack()
        })
        if player.sleepTimer != .off {
            entries.append(.action(String(localized: "Turn off timer"), systemImage: "moon.zzz") { player.cancelSleepTimer() })
        }
        return entries
    }
}

@MainActor
enum TrackMenuEntries {
    /// The menu for a song — or, when it's part of a multi-selection, for all the selected songs.
    /// Laid out as: what to do with the song, then where to go from it, then sharing.
    static func make(for track: Track, selection: [Track] = [], editing: PlaylistEditing? = nil) -> [MenuEntry] {
        if selection.count > 1, selection.contains(where: { $0.id == track.id }) {
            return make(forSelection: selection, editing: editing)
        }
        let router = Router.shared
        let player = PlayerController.shared
        let filter = ContentFilter.shared
        let queueEntries: [MenuEntry] = [
            .action(String(localized: "Add to queue"), systemImage: "text.append") {
                player.addToQueue([track])
                router.showToast(String(localized: "Added to queue"))
            },
            .action(String(localized: "Play next"), systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.playNext(track)
                router.showToast(String(localized: "Playing next"))
            },
        ]
        if track.isLocal {
            // A file on this Mac: none of YouTube's song actions apply.
            var entries = queueEntries
            if let editing, editing.canRemove(track) {
                entries.append(.action(editing.removeTitle, systemImage: "minus.circle") { editing.remove([track]) })
            }
            if let path = track.localPath {
                entries += [.divider, .action(String(localized: "Show in Finder"), systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }]
            }
            return entries
        }
        let liked = player.isLiked(track)
        var entries: [MenuEntry] = [PlaylistTargets.submenu(for: [track])]
        if let editing, editing.canRemove(track) {
            entries.append(.action(editing.removeTitle, systemImage: "minus.circle") { editing.remove([track]) })
        }
        entries.append(.item(MenuItemSpec(title: liked ? String(localized: "Remove like") : String(localized: "Like"),
                                          icon: liked ? .likedSongsRemove : .likedSongs) {
            player.setLiked(!liked, track)
            guard AuthManager.shared.isSignedIn else { return }
            router.showToast(liked ? String(localized: "Removed from Liked Music") : String(localized: "Added to Liked Music")) { player.setLiked(liked, track) }
        }))
        entries += queueEntries
        entries.append(.submenu(String(localized: "Don't recommend"), systemImage: "xmark.circle", dontRecommend(track, filter: filter)))
        entries.append(.submenu(String(localized: "Sleep timer"), systemImage: "timer", SleepTimerEntries.make()))
        if ListenTogether.shared.role == .off {
            entries.append(.action(String(localized: "Start a listening session"), systemImage: "person.2.wave.2") {
                ListenTogetherActions.start { player.playRadio(from: track) }
            })
        }
        entries += [
            .divider,
            .action(String(localized: "Go to song radio"), systemImage: "dot.radiowaves.left.and.right") { router.navigate(.radio(RadioSeed(track: track))) },
            .action(String(localized: "Start song radio"), systemImage: "play.circle") { player.playRadio(from: track) },
        ]
        let artists = track.artists.filter { $0.browseId != nil }
        if artists.count > 1 {
            entries.append(.submenu(String(localized: "Go to artist"), systemImage: "person", artists.map { artist in
                .action(artist.name, systemImage: "") { router.open(artist: artist) }
            }))
        } else if let artist = artists.first {
            entries.append(.action(String(localized: "Go to artist"), systemImage: "person") { router.open(artist: artist) })
        }
        if let album = track.album, album.browseId != nil {
            entries.append(.action(String(localized: "Go to album"), systemImage: "smallcircle.filled.circle") { router.open(album: album) })
        }
        entries += [
            .action(String(localized: "View credits"), systemImage: "music.quarternote.3") { router.creditsTrack = track },
            .submenu(String(localized: "Share"), systemImage: "square.and.arrow.up", [
                .action(String(localized: "Copy song link"), systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("https://music.youtube.com/watch?v=\(track.videoId)", forType: .string)
                    router.showToast(String(localized: "Link copied to clipboard"))
                },
                .action(String(localized: "Share…"), systemImage: "square.and.arrow.up") {
                    SharePicker.show([URL(string: "https://music.youtube.com/watch?v=\(track.videoId)")!, "\(track.title) — \(track.artistLine)"])
                },
            ]),
        ]
        return entries
    }

    /// Everything that keeps a song (or its artist) out of what you hear, in one place.
    private static func dontRecommend(_ track: Track, filter: ContentFilter) -> [MenuEntry] {
        let player = PlayerController.shared
        let router = Router.shared
        let disliked = player.isDisliked(track)
        let hidden = filter.hiddenSongs.contains { $0.id == track.videoId }
        var entries: [MenuEntry] = [
            .action(disliked ? String(localized: "Remove Dislike") : String(localized: "Dislike"), systemImage: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                player.setDisliked(!disliked, track)
                if AuthManager.shared.isSignedIn, !disliked { router.showToast(String(localized: "Thanks — you'll hear less like this"), icon: "hand.thumbsdown.fill") }
            },
            hidden
                ? .action(String(localized: "Unhide Song"), systemImage: "eye") { filter.unhide(songId: track.videoId) }
                : .action(String(localized: "Hide Song"), systemImage: "eye.slash") { filter.hide(track) },
        ]
        if filter.isSnoozed(track) {
            entries.append(.action(String(localized: "Unsnooze"), systemImage: "alarm") { filter.unsnooze(track) })
        } else if !hidden {
            entries.append(.action(String(localized: "Snooze for 30 Days"), systemImage: "moon.zzz") { filter.snooze(track) })
        }
        if let artist = track.artists.first {
            entries.append(filter.isArtistHidden(artist)
                ? .action(String(localized: "Allow \(artist.name)"), systemImage: "person.crop.circle.badge.checkmark") {
                    filter.unhide(artistId: artist.browseId ?? "name:\(artist.name.lowercased())")
                }
                : .action(String(localized: "Don't Play \(artist.name)"), systemImage: "person.crop.circle.badge.xmark") { filter.hide(artist: artist) })
        }
        entries.append(.divider)
        if filter.aiSongs.contains(where: { $0.id == track.videoId }) {
            entries.append(.action(String(localized: "Not AI"), systemImage: "sparkles") { filter.unmarkAI(songId: track.videoId, artistId: nil) })
        } else {
            entries.append(.action(String(localized: "Mark as AI"), systemImage: "sparkles") { filter.markAI(track, includingArtist: false) })
            if let artist = track.artists.first, !filter.isAIArtist(artist) {
                entries.append(.action(String(localized: "Mark \(artist.name) as AI Artist"), systemImage: "sparkles.rectangle.stack") {
                    filter.markAI(track, includingArtist: true)
                })
            }
        }
        return entries
    }

    /// The menu for several selected songs.
    static func make(forSelection tracks: [Track], editing: PlaylistEditing?) -> [MenuEntry] {
        let router = Router.shared
        let player = PlayerController.shared
        var entries: [MenuEntry] = [
            .action(String(localized: "Play \(tracks.count) Songs"), systemImage: "play.fill") { player.play(tracks) },
            .action(String(localized: "Add to Queue"), systemImage: "text.append") {
                player.addToQueue(tracks)
                router.showToast(String(localized: "Added \(tracks.count) songs to queue"))
            },
            .action(String(localized: "Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.playNext(tracks)
                router.showToast(String(localized: "Playing \(tracks.count) songs next"))
            },
            .divider,
            PlaylistTargets.submenu(for: tracks),
            .action(String(localized: "Like"), systemImage: "plus.circle") {
                guard AuthManager.shared.isSignedIn else { router.showSignIn = true; return }
                for track in tracks where !player.isLiked(track) { player.setLiked(true, track) }
                router.showToast(String(localized: "Added \(tracks.count) songs to Liked Music"))
            },
        ]
        entries.append(.action(String(localized: "Hide \(tracks.count) Songs"), systemImage: "eye.slash") {
            ContentFilter.shared.hide(tracks)
        })
        if let editing, tracks.contains(where: editing.canRemove) {
            entries.append(.action(editing.removeTitle, systemImage: "trash") { editing.remove(tracks.filter(editing.canRemove)) })
        }
        entries += [
            .divider,
            .action(String(localized: "Copy Song Links"), systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tracks.map { "https://music.youtube.com/watch?v=\($0.videoId)" }.joined(separator: "\n"), forType: .string)
                router.showToast(String(localized: "Links copied to clipboard"))
            },
        ]
        return entries
    }
}


/// The system share sheet (Messages, AirDrop, Mail…) at the pointer.
@MainActor
enum SharePicker {
    static func show(_ items: [Any]) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: items).show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }
}


/// Context menu for albums, playlists and artists. Pages pass their header (library and
/// subscription state, playlist ids) and loaded songs; cards fetch what they need on demand.
/// The menu for an album, playlist, artist or podcast (right-click, ⋯).
@MainActor
enum MediaMenuEntries {
    /// `owned`: your own playlist (nothing to save, it's already yours).
    static func make(_ item: MediaItem, header: PageHeader? = nil, tracks: [Track]? = nil, owned: Bool = false) -> [MenuEntry] {
        let router = Router.shared
        let player = PlayerController.shared
        let signedIn = AuthManager.shared.isSignedIn
        let library = LocalLibrary.shared
        let account = AccountLibrary.shared
        let downloads = DownloadManager.shared
        let isCollection = item.target.kind == .album || item.target.kind == .playlist
        let isLikedSongs = ["VLLM", "LM"].contains(item.target.browseId)
        // Album cards carry the album's playlist id; that's enough to save it without opening it.
        let effectiveHeader: PageHeader? = header == nil && item.target.kind == .album && item.playlistId != nil
            ? PageHeader(title: item.title, playlistId: item.playlistId) : header
        var entries: [MenuEntry] = []

        if item.target.kind != .other {
            entries += [
                .action(String(localized: "Play"), systemImage: "play.fill") { player.playCollection(item.target, playlistId: item.playlistId) },
                .action(String(localized: "Shuffle Play"), systemImage: "shuffle") {
                    player.playCollection(item.target, playlistId: item.playlistId, shuffled: true)
                },
            ]
            if !isLikedSongs {
                entries.append(.action(item.target.kind == .artist ? String(localized: "Start Artist Mix") : String(localized: "Start Radio"),
                                       systemImage: "dot.radiowaves.left.and.right") { player.startRadio(for: item, header: header) })
                if item.target.kind != .podcast {
                    entries.append(.action(item.target.kind == .artist ? String(localized: "Go to Artist Radio") : String(localized: "Go to Radio"),
                                           systemImage: "list.bullet.rectangle") { router.navigate(.radio(RadioSeed(item: item))) })
                }
            }
            entries += [
                .action(String(localized: "Add to Queue"), systemImage: "text.append") { enqueue(item, tracks: tracks, next: false) },
                .action(String(localized: "Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward") { enqueue(item, tracks: tracks, next: true) },
            ]
            if ListenTogether.shared.role == .off, !isLikedSongs || signedIn {
                entries.append(.action(String(localized: "Start a listening session"), systemImage: "person.2.wave.2") {
                    ListenTogetherActions.start { player.playCollection(item.target, playlistId: item.playlistId) }
                })
            }
            entries.append(.divider)
        }
        if isCollection, !owned, !isLikedSongs, signedIn, AccountLibrary.libraryId(target: item.target, header: effectiveHeader) != nil {
            let saved = account.isSaved(item, header: effectiveHeader)
            entries.append(.action(saved ? String(localized: "Remove from Your Library") : String(localized: "Save to Your Library"),
                                   systemImage: saved ? "minus.circle" : "plus.circle") { account.toggleSaved(item, header: effectiveHeader) })
        }
        if item.target.kind == .artist, signedIn, header?.channelId != nil {
            let following = account.isSubscribed(item, header: header)
            entries.append(.action(following ? String(localized: "Unsubscribe") : String(localized: "Subscribe"),
                                   systemImage: following ? "person.badge.minus" : "person.badge.plus") { account.toggleSubscribed(item, header: header) })
        }
        if item.target.kind == .artist {
            let artist = ArtistRef(name: item.title, browseId: item.target.browseId)
            let filter = ContentFilter.shared
            if filter.isArtistHidden(artist) {
                entries.append(.action(String(localized: "Allow This Artist"), systemImage: "person.crop.circle.badge.checkmark") {
                    filter.unhide(artistId: item.target.browseId)
                })
            } else {
                entries.append(.action(String(localized: "Don't Play This Artist"), systemImage: "person.crop.circle.badge.xmark") { filter.hide(artist: artist) })
            }
            if !filter.isAIArtist(artist) {
                entries.append(.action(String(localized: "Mark as AI Artist"), systemImage: "sparkles") { filter.markAI(artist: artist) })
            } else if filter.aiArtists.contains(where: { $0.id == item.target.browseId }) {
                entries.append(.action(String(localized: "Not an AI Artist"), systemImage: "sparkles") {
                    filter.unmarkAI(songId: nil, artistId: item.target.browseId)
                })
            }
        }
        if isCollection {
            if downloads.state(for: item.target) == .none {
                entries.append(.action(String(localized: "Download"), systemImage: "arrow.down.circle") { download(item, header: header, tracks: tracks) })
            } else {
                entries.append(.action(String(localized: "Remove Download"), systemImage: "arrow.down.circle.fill") { downloads.remove(item.target) })
            }
        }
        if item.target.kind != .other {
            var folderEntries: [MenuEntry] = [.action(String(localized: "New Folder"), systemImage: "folder.badge.plus") {
                library.move(item, to: library.createFolder())
            }]
            if !library.folders.isEmpty { folderEntries.append(.divider) }
            folderEntries += library.folders.map { folder in
                .choice(folder.name, systemImage: "folder", selected: library.folder(containing: item)?.id == folder.id) { library.move(item, to: folder) }
            }
            if library.folder(containing: item) != nil {
                folderEntries += [.divider, .action(String(localized: "Remove from Folder"), systemImage: "folder.badge.minus") { library.move(item, to: nil) }]
            }
            entries.append(.submenu(String(localized: "Move to Folder"), systemImage: "folder", folderEntries))
        }
        let pinned = library.isPinned(item)
        entries += [
            .action(pinned ? String(localized: "Unpin from Your Library") : String(localized: "Pin to Your Library"),
                    systemImage: pinned ? "pin.slash" : "pin") { library.togglePin(item) },
            .divider,
            .submenu(String(localized: "Share"), systemImage: "square.and.arrow.up", [
                .action(String(localized: "Copy Link"), systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link(item).absoluteString, forType: .string)
                    router.showToast(String(localized: "Link copied to clipboard"))
                },
                .action(String(localized: "Share…"), systemImage: "square.and.arrow.up") { SharePicker.show([link(item), item.title]) },
            ]),
        ]
        return entries
    }

    static func link(_ item: MediaItem) -> URL {
        let path = item.target.kind == .artist ? "channel/\(item.target.browseId)"
            : item.target.browseId.hasPrefix("VL") ? "playlist?list=\(item.target.browseId.dropFirst(2))"
            : "browse/\(item.target.browseId)"
        return URL(string: "https://music.youtube.com/\(path)")!
    }

    private static func download(_ item: MediaItem, header: PageHeader?, tracks: [Track]?) {
        let downloads = DownloadManager.shared
        if let tracks, !tracks.isEmpty {
            downloads.download(item, header: header, tracks: tracks)
            return
        }
        Task {
            guard let loaded = try? await MusicAPI.collectionTracks(item.target), !loaded.tracks.isEmpty else {
                Router.shared.showToast(String(localized: "Couldn't download \(item.title)"), icon: "exclamationmark.triangle.fill")
                return
            }
            downloads.download(item, header: loaded.header, tracks: loaded.tracks)
        }
    }

    private static func enqueue(_ item: MediaItem, tracks: [Track]?, next: Bool) {
        Task {
            let songs: [Track]
            if let tracks, !tracks.isEmpty {
                songs = tracks
            } else {
                songs = (try? await MusicAPI.collectionTracks(item.target, limit: 500))?.tracks ?? []
            }
            guard !songs.isEmpty else { return }
            if next { PlayerController.shared.playNext(songs) } else { PlayerController.shared.addToQueue(songs) }
            Router.shared.showToast(next ? String(localized: "Playing next") : String(localized: "Added to queue"))
        }
    }
}

// MARK: - Small pieces

/// Clickable artist names, each linking to its page.
/// A card's subtitle ("Album • Banda XXI") with each artist's name a link to their page, the rest
/// plain. Only while the card is hovered: plain text otherwise, so a scrolling shelf carries no
/// link regions.
struct LinkedSubtitle: View {
    var text: String
    var artists: [ArtistRef]
    var interactive: Bool
    var lines = 2
    var font: Font = .system(size: 13)
    @Environment(Router.self) private var router

    var body: some View {
        Text(interactive && !artists.isEmpty ? linked : AttributedString(text))
            .font(font)
            .foregroundStyle(Theme.secondary)
            .tint(Theme.text)
            .lineLimit(lines, reservesSpace: lines > 1)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "ytmusicfast-artist", let index = Int(url.lastPathComponent),
                      artists.indices.contains(index) else { return .discarded }
                router.open(artist: artists[index])
                return .handled
            })
    }

    private var linked: AttributedString {
        var line = AttributedString(text)
        var searchFrom = line.startIndex
        for (index, artist) in artists.enumerated() {
            guard let range = line[searchFrom...].range(of: artist.name) else { continue }
            line[range].link = URL(string: "ytmusicfast-artist://open/\(index)")
            searchFrom = range.upperBound
        }
        return line
    }
}

struct ArtistLinks: View {
    var artists: [ArtistRef]
    var font: Font = .system(size: 13)
    var color: Color = Theme.secondary
    /// False: one plain line of text. Long lists pass false for rows that aren't hovered, so
    /// scrolling doesn't carry a click, hover and cursor region for every artist name.
    var interactive = true
    @Environment(Router.self) private var router

    var body: some View {
        if interactive {
            // Each name its own hover-underlined link while they fit; otherwise one line cut at
            // its end — still clickable, as links inside the text.
            ViewThatFits(in: .horizontal) {
                links.fixedSize()
                linkedLine
            }
        } else {
            Text(artists.isEmpty ? String(localized: "Unknown artist") : artists.map(\.name).joined(separator: ", "))
                .font(font)
                .lineLimit(1)
                .foregroundStyle(color)
        }
    }

    /// One text with each artist as a link: truncates as a whole instead of name by name.
    private var linkedLine: some View {
        var line = AttributedString()
        for (index, artist) in artists.enumerated() {
            if index > 0 { line += AttributedString(", ") }
            var name = AttributedString(artist.name)
            if artist.browseId != nil { name.link = URL(string: "ytmusicfast-artist://open/\(index)") }
            line += name
        }
        if artists.isEmpty { line = AttributedString(String(localized: "Unknown artist")) }
        return Text(line)
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(color)
            .tint(color)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "ytmusicfast-artist", let index = Int(url.lastPathComponent),
                      artists.indices.contains(index) else { return .discarded }
                router.open(artist: artists[index])
                return .handled
            })
    }

    private var links: some View {
        HStack(spacing: 0) {
            if artists.isEmpty {
                Text("Unknown artist")
            }
            ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                if index > 0 { Text(", ") }
                if artist.browseId != nil {
                    Text(artist.name)
                        .onTapGesture { router.open(artist: artist) }
                        .hoverUnderline()
                } else {
                    Text(artist.name)
                }
            }
        }
        .font(font)
        .lineLimit(1)
        .foregroundStyle(color)
    }
}

struct HoverUnderline: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .underline(hovering)
            .onHover { hovering = $0 }
            .pointerStyle(.link)
    }
}

extension View {
    func hoverUnderline() -> some View { modifier(HoverUnderline()) }
}

/// Animated "playing" indicator: four bars bouncing. Plain Core Animation layers,
/// animated by the system's render server, so the app does no work per frame. (A repeating
/// SF Symbol effect looked the same but redrew its layer in the app on every frame — about 15%
/// CPU while a song played with the indicator on screen.)
struct EqualizerBars: View {
    var animating: Bool

    var body: some View {
        EqualizerBarsLayer(animating: animating, color: NSColor(Theme.accent))
            .frame(width: 16, height: 14)
            .accessibilityHidden(true)
    }
}

private struct EqualizerBarsLayer: NSViewRepresentable {
    var animating: Bool
    var color: NSColor

    func makeNSView(context: Context) -> BarsView { BarsView() }

    func updateNSView(_ view: BarsView, context: Context) {
        view.update(animating: animating, color: color)
    }

    final class BarsView: NSView {
        private let bars = (0..<4).map { _ in CALayer() }
        private var animating: Bool?
        /// Each bar's resting height and its own rhythm, so they never move in step.
        private static let rest: [CGFloat] = [0.45, 0.8, 0.6, 0.35]
        private static let peaks: [[CGFloat]] = [[0.3, 1.0, 0.5, 0.85, 0.3], [0.9, 0.4, 1.0, 0.55, 0.9],
                                                 [0.5, 0.85, 0.35, 1.0, 0.5], [0.7, 0.3, 0.9, 0.45, 0.7]]
        private static let durations: [CFTimeInterval] = [1.1, 0.9, 1.25, 1.0]

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for bar in bars {
                bar.anchorPoint = CGPoint(x: 0.5, y: 0)
                bar.cornerRadius = 1
                layer?.addSublayer(bar)
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let width: CGFloat = 2.5
            let gap = (bounds.width - width * 4) / 3
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, bar) in bars.enumerated() {
                bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
                bar.position = CGPoint(x: CGFloat(index) * (width + gap) + width / 2, y: 0)
            }
            CATransaction.commit()
        }

        // Layers keep their animations across window moves; re-add if the view comes back.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let animating, window != nil { apply(animating) }
        }

        func update(animating: Bool, color: NSColor) {
            let cgColor = color.cgColor
            for bar in bars where bar.backgroundColor != cgColor { bar.backgroundColor = cgColor }
            guard animating != self.animating else { return }
            self.animating = animating
            apply(animating)
        }

        private func apply(_ animating: Bool) {
            for (index, bar) in bars.enumerated() {
                bar.removeAnimation(forKey: "bounce")
                bar.transform = CATransform3DMakeScale(1, Self.rest[index], 1)
                guard animating else { continue }
                let bounce = CAKeyframeAnimation(keyPath: "transform.scale.y")
                bounce.values = Self.peaks[index]
                bounce.duration = Self.durations[index]
                bounce.repeatCount = .infinity
                bounce.calculationMode = .cubic
                bounce.isRemovedOnCompletion = false
                bar.add(bounce, forKey: "bounce")
            }
        }
    }
}

// MARK: - Track table

struct TrackList: View {
    var tracks: [Track]
    var showArtwork = true
    var showAlbum = true
    var showHeader = false
    var numbered = true
    var showPlays = false
    /// Off on an artist's own page: every song is theirs, so rows show only the title.
    var showArtists = true
    /// Shows only the first this many (an artist's Popular, before "See more"); playing still
    /// queues the whole list.
    var visibleCount: Int?
    /// Forces the length column on or off; nil: shown when any song has a length.
    var durationColumn: Bool?
    var onLoadMore: (() -> Void)?
    /// Selection: click, ⌘-click to add, ⇧-click for a range.
    @State private var selection: Set<Int> = []
    @State private var anchor: Int?
    /// The row the arrow keys last moved to (the moving end of a ⇧-arrow range).
    @State private var cursor: Int?
    @State private var width: CGFloat = 0
    /// Identifies this list as the owner of the clipboard keys.
    @State private var clipboardOwner = UUID()
    @Environment(\.playContext) private var context
    @Environment(\.playlistEditing) private var editing
    @Environment(\.searchOrigin) private var searchOrigin

    /// Wide enough for the longest number, so "214" never wraps and every row lines up.
    static func numberWidth(for count: Int) -> CGFloat { max(24, CGFloat(String(count).count) * 9 + 4) }
    private var numberWidth: CGFloat { Self.numberWidth(for: tracks.count) }

    /// Column widths worked out once for the whole list (they only change when the window
    /// does), so each row lays out with fixed frames instead of negotiating flexible ones.
    /// No song in the list has a length (e.g. YouTube's "Quick picks"): no column for them.
    private var showsDurations: Bool { durationColumn ?? tracks.contains { $0.duration != nil } }

    private var columns: TrackColumns? {
        guard width > 0 else { return nil }
        let hasNumber = numbered || !showArtwork
        let flexible = 1 + (showAlbum ? 1 : 0)
        let children = (hasNumber ? 1 : 0) + flexible + (showPlays ? 1 : 0) + 1
        let fixed = 32 + (showsDurations ? TrackRow.trailingWidth : TrackRow.trailingWidthWithoutDuration)
            + (hasNumber ? numberWidth : 0) + (showPlays ? TrackRow.playsWidth : 0)
            + CGFloat(children - 1) * 16
        let share = max(40, ((width - fixed) / CGFloat(flexible)).rounded(.down))
        return TrackColumns(flexible: share, row: width)
    }

    private func select(_ index: Int) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift), let anchor {
            selection.formUnion(min(anchor, index)...max(anchor, index))
        } else if flags.contains(.command) {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
            anchor = index
        } else {
            selection = [index]
            anchor = index
        }
        cursor = index
    }

    /// ↑ / ↓ move the selection (⇧ extends it), Return plays from the first selected song.
    private func handleKey(_ key: SelectionKeys.Key, extend: Bool, proxy: ScrollViewProxy) -> Bool {
        guard !selection.isEmpty, !tracks.isEmpty else { return false }
        switch key {
        case .play:
            guard let first = selection.min(), tracks.indices.contains(first) else { return false }
            PlayerController.shared.play(tracks, startAt: first, from: context)
        case .up, .down:
            let from = cursor ?? (key == .up ? selection.min() : selection.max()) ?? 0
            let target = min(max(0, from + (key == .up ? -1 : 1)), tracks.count - 1)
            if extend, let anchor {
                selection = Set(min(anchor, target)...max(anchor, target))
            } else {
                selection = [target]
                anchor = target
            }
            cursor = target
            proxy.scrollTo(Self.rowID(target))
        }
        return true
    }

    private static func rowID(_ index: Int) -> String { "track-row-\(index)" }

    /// ⌘A / ⌘C / ⌘X / ⌘V on songs: select all, copy and cut as music.youtube.com
    /// links, and paste links into your playlist.
    private func handleClipboard(_ action: ListClipboard.Action) -> Bool {
        let router = Router.shared
        switch action {
        case .selectAll:
            guard !tracks.isEmpty else { return false }
            selection = Set(tracks.indices)
            anchor = 0
            cursor = tracks.count - 1
        case .copy:
            let selected = selectedTracks()
            guard !selected.isEmpty else { return false }
            ListClipboard.write(selected)
            router.showToast(selected.count == 1 ? String(localized: "Link copied") : String(localized: "Copied \(selected.count) links"),
                             icon: "link")
        case .cut:
            guard let editing else { return false }
            let removable = selectedTracks().filter(editing.canRemove)
            guard !removable.isEmpty else { return false }
            ListClipboard.write(removable)
            selection = []
            editing.remove(removable)
        case .paste(let ids):
            guard let add = editing?.add, !ids.isEmpty else { return false }
            add(ids)
        }
        return true
    }

    private func selectedTracks() -> [Track] {
        selection.sorted().compactMap { tracks.indices.contains($0) ? tracks[$0] : nil }
    }

    /// A song dragged within your playlist lands before the row it's dropped on; songs dragged in
    /// from elsewhere are added there.
    private func dropHandler(at index: Int) -> ((String) -> Bool)? {
        guard let move = editing?.move else { return nil }
        let insert = editing?.insert
        return { payload in
            let ids = TrackDrag.videoIds(in: [payload])
            guard !ids.isEmpty else { return false }
            if ids.count == 1, let source = tracks.first(where: { $0.videoId == ids[0] }), source.setVideoId != nil {
                move(source, index)
            } else if let insert {
                insert(ids, index)
            } else {
                return false
            }
            selection = []
            return true
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if showHeader {
                    TrackListHeader(showAlbum: showAlbum, showPlays: showPlays, showDuration: showsDurations, numberWidth: numberWidth)
                        .padding(.bottom, 12)
                }
                LazyVStack(spacing: 0) {
                    ForEach(tracks.indices.prefix(visibleCount ?? tracks.count), id: \.self) { index in
                        TrackRow(track: tracks[index], index: index, showArtwork: showArtwork, showAlbum: showAlbum,
                                 numbered: numbered, showPlays: showPlays, showArtists: showArtists, showDuration: showsDurations, selected: selection.contains(index), numberWidth: numberWidth,
                                 columns: columns, onSelect: { select(index) }, selection: selectedTracks,
                                 onDrop: dropHandler(at: index)) {
                            if searchOrigin { RecentSearches.add(.track(tracks[index])) }
                            PlayerController.shared.play(tracks, startAt: index, from: context)
                        }
                        .id(Self.rowID(index))
                        // Explicitly none: otherwise the list searches every new row's branches for
                        // a transition to run, which cost a lot per row on fast scrolls.
                        .transition(.identity)
                        .onAppear {
                            // Ask for the next batch well before the end, so it arrives off screen and its
                            // rows get built a few at a time as they scroll in, not all in one frame.
                            if visibleCount == nil, index == max(0, tracks.count - 60) { onLoadMore?() }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }

            }
            // Rows moved or removed: old indices would point at other songs.
            .onChange(of: tracks.count) { selection = []; anchor = nil; cursor = nil }
            .background {
                // Esc clears the selection; Delete removes it from your playlist (or your history).
                if !selection.isEmpty {
                    Button("") { selection = [] }.keyboardShortcut(.cancelAction).opacity(0)
                }
            }
            .onAppear {
                ListClipboard.register(clipboardOwner) { handleClipboard($0) }
            }
            .onChange(of: selection) { _, selected in
                // Arrow keys and Return (handled by the app, which knows when you're typing) act on
                // the list you last selected in.
                if !selected.isEmpty {
                    SelectionKeys.handler = { key, extend in handleKey(key, extend: extend, proxy: proxy) }
                    ListClipboard.register(clipboardOwner) { handleClipboard($0) }
                }
                // The Delete key acts on this list too.
                guard let editing, !selected.isEmpty else { return }
                SelectionDelete.handler = {
                    let tracks = selectedTracks().filter(editing.canRemove)
                    guard !tracks.isEmpty else { return false }
                    selection = []
                    editing.remove(tracks)
                    return true
                }
            }
            .onDisappear {
                SelectionDelete.handler = nil
                SelectionKeys.handler = nil
                ListClipboard.unregister(clipboardOwner)
            }
        }
    }
}

/// What ↑, ↓ and Return act on: the list you last selected songs in.
@MainActor
enum SelectionKeys {
    enum Key { case up, down, play }
    /// Returns whether the key was used; the Bool says ⇧ was held (extend the selection).
    static var handler: ((Key, Bool) -> Bool)?
}

/// What the Delete key removes: the selected songs of the list you last selected in.
@MainActor
enum SelectionDelete {
    static var handler: (() -> Bool)?
}

/// ⌘A / ⌘C / ⌘X / ⌘V for song lists: the list you last selected in (or that opened last).
@MainActor
enum ListClipboard {
    enum Action {
        case selectAll, copy, cut
        /// Video ids of the song links on the clipboard.
        case paste([String])
    }

    private static var owner: UUID?
    private static var handler: ((Action) -> Bool)?

    static func register(_ id: UUID, _ handle: @escaping (Action) -> Bool) {
        owner = id
        handler = handle
    }

    /// Only the list that registered last can unregister (another may have taken over).
    static func unregister(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        handler = nil
    }

    /// Whether a list used the keys (otherwise they do their usual job).
    static func perform(_ action: Action) -> Bool { handler?(action) ?? false }

    static func write(_ tracks: [Track]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TrackDrag.payload(tracks), forType: .string)
    }

    /// Song ids in the clipboard's links (albums, playlists and other links are skipped).
    static func songIds() -> [String] {
        guard let text = NSPasteboard.general.string(forType: .string) else { return [] }
        return TrackDrag.videoIds(in: [text])
    }
}

/// Songs travel as their music.youtube.com links: dropping them in another app gives the link.
enum TrackDrag {
    static func payload(_ tracks: [Track]) -> String {
        tracks.map { "https://music.youtube.com/watch?v=\($0.videoId)" }.joined(separator: "\n")
    }

    /// Video ids in `watch?v=` links (music.youtube.com, youtube.com) and `youtu.be/` links.
    static func videoIds(in payloads: [String]) -> [String] {
        payloads.flatMap { $0.split(whereSeparator: \.isNewline) }.compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let components = URLComponents(string: text) else { return nil }
            if components.host?.hasSuffix("youtu.be") == true {
                let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return id.isEmpty ? nil : id
            }
            return components.queryItems?.first { $0.name == "v" }?.value
        }
    }
}

/// Width of each flexible column (title, album, plays) in a track list.
struct TrackColumns: Equatable {
    var flexible: CGFloat
    /// The whole row. With width and height both fixed, the list can size a row without laying
    /// out its contents, which it does for every row it skips past on a fast scroll.
    var row: CGFloat
}

private struct ColumnFrame: ViewModifier {
    var width: CGFloat?

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, alignment: .leading)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// A fixed column width once the list knows it, flexible until then.
    func columnFrame(_ width: CGFloat?) -> some View { modifier(ColumnFrame(width: width)) }
}

/// The "# · Title · Album · ⏱" row above a track list; also pinned under the sticky bar.
struct TrackListHeader: View {
    var showAlbum: Bool
    var showPlays = false
    var showDuration = true
    var numberWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("#").frame(width: numberWidth, alignment: .trailing)
                Text("Title").frame(maxWidth: .infinity, alignment: .leading)
                if showPlays { Text("Plays").frame(width: TrackRow.playsWidth, alignment: .trailing) }
                if showAlbum { Text("Album").frame(maxWidth: .infinity, alignment: .leading) }
                // The clock sits over the durations: the same width as the rows' trailing column,
                // minus the ⋯ button and its spacing.
                if showDuration {
                    Image(systemName: "clock")
                        .frame(width: TrackRow.trailingWidth - 32, alignment: .trailing)
                        .padding(.trailing, 32)
                } else {
                    Color.clear.frame(width: TrackRow.trailingWidthWithoutDuration, height: 1)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            Rectangle().fill(Theme.text.opacity(0.1)).frame(height: 1)
        }
    }
}

/// A row's hover: from its list when the list tracks it (one region for all rows), else its own.
/// Either way, buttons and menus (`engaged`) wait until the pointer rests.
private struct RowHover: ViewModifier {
    var external: Bool?
    @Binding var own: Bool
    @Binding var engaged: Bool
    /// Bumped on every change, so a delayed "engage" from an earlier hover can't land late.
    @State private var generation = 0

    func body(content: Content) -> some View {
        if let external {
            content.onChange(of: external, initial: true) { _, inside in
                generation += 1
                let current = generation
                if inside {
                    Task {
                        try? await Task.sleep(for: .milliseconds(90))
                        if generation == current { engaged = true }
                    }
                } else {
                    engaged = false
                }
            }
        } else {
            content.onHover($own, engaged: $engaged)
        }
    }
}

/// Lets a row be dragged (to a playlist in Your Library, or within your playlist).
/// Always attached: switching it on only while hovered rebuilt the row each time, which reset its
/// hover and made the play button flicker and swallow clicks. The payload and preview are only
/// worked out when a drag actually starts.
extension View {
    /// Lets a song be dragged out (onto a playlist, or into another app as its link).
    func trackDraggable(_ track: Track) -> some View {
        modifier(TrackDragSource(payload: { TrackDrag.payload([track]) }, count: { 1 }))
    }
}

private struct TrackDragSource: ViewModifier {
    var payload: () -> String
    var count: () -> Int

    func body(content: Content) -> some View {
        content.draggable(payload()) {
            let n = count()
            Label(Format.count(n, .song), systemImage: "music.note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.accent))
        }
    }
}

private struct TrackDropTarget: ViewModifier {
    var onDrop: ((String) -> Bool)?
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if let onDrop {
            content.dropDestination(for: String.self) { items, _ in
                items.first.map(onDrop) ?? false
            } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

/// The small download arrow on songs saved for offline.
struct DownloadedBadge: View {
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("Downloaded")
    }
}

/// Marks songs the filter thinks are AI-generated; the tooltip says why.
struct AIBadge: View {
    var reason: String?

    var body: some View {
        Text("AI")
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.black)
            .padding(.horizontal, 3)
            .frame(height: 14)
            .background(RoundedRectangle(cornerRadius: 2).fill(Color.orange))
            .help(reason ?? String(localized: "Looks AI-generated"))
            .accessibilityLabel("AI-generated")
    }
}

/// The small "E" for explicit songs.
struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 14, height: 14)
            .background(RoundedRectangle(cornerRadius: 2).fill(Theme.secondary))
            .accessibilityLabel("Explicit")
    }
}

/// The ✓ on songs in Liked Music; while hovering, a + to save one that isn't.
struct LikeToggle: View {
    var track: Track
    var hovering: Bool
    private var player: PlayerController { .shared }

    var body: some View {
        let liked = player.isLiked(track)
        Button { player.setLiked(!liked, track) } label: {
            Image(systemName: liked ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 15))
                .foregroundStyle(liked ? Theme.accent : Theme.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(liked || hovering ? 1 : 0)
        .accessibilityLabel(liked ? String(localized: "Remove like") : String(localized: "Like"))
    }
}

struct TrackRow: View {
    /// ✓, duration and ⋯ on the right of every row.
    static let trailingWidth: CGFloat = 112
    /// The same without a duration (a list where no song has one).
    static let trailingWidthWithoutDuration: CGFloat = 52
    /// Play counts (an artist's songs): a narrow column by the durations.
    static let playsWidth: CGFloat = 120

    var track: Track
    var index: Int
    var showArtwork = true
    var showAlbum = true
    var numbered = true
    var showPlays = false
    var showArtists = true
    /// In a shelf's grid (no columns to line up with): the buttons take only the room they need,
    /// and there's no gap where a missing length would go.
    var compact = false
    var showDuration = true
    var selected = false
    var numberWidth: CGFloat = 24
    var columns: TrackColumns?
    /// Set by a list that tracks hover itself; nil means the row tracks its own.
    var hovered: Bool?
    var onSelect: (() -> Void)?
    /// The list's selected songs, asked for only when a menu or drag needs them.
    var selection: () -> [Track] = { [] }
    /// Your playlist: another of its songs dropped here moves before this one.
    var onDrop: ((String) -> Bool)?
    var play: () -> Void

    @State private var ownHover = false
    @State private var engaged = false
    @State private var dropTargeted = false
    private var hovering: Bool { hovered ?? ownHover }
    @Environment(Router.self) private var router
    @Environment(\.playlistEditing) private var editing
    private var player: PlayerController { .shared }

    /// What a menu or drag acts on: the whole selection when this row is part of it.
    private var actedOn: [Track] {
        let selected = selected ? selection() : []
        return selected.count > 1 ? selected : [track]
    }

    private var isCurrent: Bool { player.current?.videoId == track.videoId }

    var body: some View {
        HStack(spacing: 16) {
            if numbered || !showArtwork {
                ZStack {
                    if hovering {
                        playToggle
                    } else if isCurrent, player.isPlaying {
                        EqualizerBars(animating: true)
                    } else if numbered {
                        Text("\(index + 1)")
                            .font(.system(size: 15).monospacedDigit())
                            .foregroundStyle(isCurrent ? Theme.accent : Theme.secondary)
                    }
                }
                .lineLimit(1)
                .frame(width: numberWidth, alignment: .trailing)
            }

            HStack(spacing: 12) {
                if showArtwork {
                    ArtworkView(url: track.thumbnail, size: 40, cornerRadius: 4)
                        .overlay {
                            // Without a number column, the play affordance sits on the artwork.
                            if !numbered, hovering || (isCurrent && player.isPlaying) {
                                RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.5))
                                if hovering { playToggle } else { EqualizerBars(animating: true) }
                            }
                        }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 15))
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                        .lineLimit(1)
                        .help(track.title)
                    let downloaded = DownloadManager.shared.isDownloaded(track)
                    let ai = ContentFilter.shared.isAI(track)
                    // Without artists, the line only shows when there's a badge for it.
                    if showArtists || downloaded || ai || track.isExplicit == true || track.isVideo {
                        HStack(spacing: 4) {
                            if downloaded { DownloadedBadge() }
                            if ai { AIBadge(reason: ContentFilter.shared.aiReason(track)) }
                            if track.isExplicit == true { ExplicitBadge() }
                            if track.isVideo {
                                Image(systemName: "play.rectangle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.secondary)
                                    .accessibilityLabel("Music video")
                                if !showArtists {
                                    Text("Music video").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                                }
                            }
                            if showArtists {
                                ArtistLinks(artists: track.artists, color: hovering ? Theme.text : Theme.secondary, interactive: engaged)
                            }
                            // Shelf grids have no plays column: the count goes with the artist.
                            if compact, let plays = track.plays {
                                Text("• " + plays).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .columnFrame(columns?.flexible)

            if showPlays {
                // "1.2B plays" → "1.2B": the column header says what they are.
                Text(track.plays.map { $0.hasSuffix(" plays") ? String($0.dropLast(6)) : $0 } ?? "")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .frame(width: Self.playsWidth, alignment: .trailing)
            }

            if showAlbum {
                Group {
                    if let album = track.album, engaged {
                        Text(album.name)
                            .onTapGesture { router.open(album: album) }
                            .hoverUnderline()
                    } else if let album = track.album {
                        Text(album.name)
                    } else {
                        Text("")
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Theme.text : Theme.secondary)
                .lineLimit(1)
                .columnFrame(columns?.flexible)
            }

            HStack(spacing: 12) {
                // Buttons only where they show: rows scrolling past the pointer stay light.
                if engaged || player.isLiked(track) {
                    LikeToggle(track: track, hovering: engaged)
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
                if showDuration, !compact || track.duration != nil {
                    Text(track.duration.map(Format.time) ?? "")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .frame(width: compact ? nil : 48, alignment: .trailing)
                }
                // A plain button that builds its menu on click: cheap to show and hide while
                // rows slide under the pointer.
                if engaged {
                    Button { MenuPresenter.shared.showContextMenu(TrackMenuEntries.make(for: track, selection: selected ? selection() : [], editing: editing)) } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("More options for \(track.title)")
                } else {
                    Color.clear.frame(width: 20, height: 20)
                }
            }
            .frame(width: compact ? nil : showDuration ? Self.trailingWidth : Self.trailingWidthWithoutDuration, alignment: .trailing)
            .fixedSize(horizontal: compact, vertical: false)
        }
        .padding(.horizontal, 16)
        .frame(width: columns?.row, height: 56)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(selected ? Theme.text.opacity(0.18) : hovering ? Theme.text.opacity(0.1) : .clear)
        )
        // Hidden songs stay in place on album/playlist pages, dimmed, and are skipped.
        .opacity((ContentFilter.shared.isHidden(track) || (player.offlineMode && !PlayerController.availableOffline(track))) && !hovering ? 0.4 : 1)
        .overlay(alignment: .top) {
            // Where a dragged song will land.
            if dropTargeted { Rectangle().fill(Theme.accent).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .modifier(RowHover(external: hovered, own: $ownHover, engaged: $engaged))
        .modifier(TrackDragSource(payload: { TrackDrag.payload(actedOn) }, count: { actedOn.count }))
        .modifier(TrackDropTarget(onDrop: onDrop, targeted: $dropTargeted))
        // One tap handler, not one per click count: every gesture is another region to test
        // on each scroll frame. The second click of a double-click plays.
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { play() } else { onSelect?() }
        }
        // Menu contents only on the hovered row (the one you can right-click): building the full
        // song menu for every row as it scrolled in was a big part of each row's cost.
        .menuOnRightClick(hovering: hovering) { TrackMenuEntries.make(for: track, selection: selected ? selection() : [], editing: editing) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(track.title), \(track.artistLine)")
        .accessibilityValue(isCurrent ? (player.isPlaying ? String(localized: "Playing") : String(localized: "Paused")) : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { play() }
        .accessibilityAction(named: "Play Next") { player.playNext(track) }
        .accessibilityAction(named: "Add to Queue") { player.addToQueue([track]) }
    }

    /// ▶ / ⏸ on the hovered row. The whole number column (or cover) is the button —
    /// a big target, not just the small glyph — clicking beside the glyph used to select the row instead.
    private var playToggle: some View {
        Button { isCurrent ? player.togglePlayPause() : play() } label: {
            Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .frame(width: numbered || !showArtwork ? max(numberWidth, 24) : 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}

/// ▶ over a cover while hovered (⏸ when it's what's playing). The whole cover is the
/// button. Nothing is built while not hovered.
struct CoverPlayOverlay: View {
    var visible: Bool
    var playing = false
    var circle = false
    var cornerRadius: CGFloat = 4
    var glyphSize: CGFloat = 16
    var action: () -> Void

    var body: some View {
        if visible {
            ZStack {
                (circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))).fill(.black.opacity(0.5))
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: glyphSize))
                    .foregroundStyle(.white)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Cards

struct MediaCard: View {
    static let defaultSize: CGFloat = 164

    var item: ShelfItem
    var size: CGFloat = MediaCard.defaultSize
    var siblings: [Track] = []

    @State private var hovering = false
    @State private var engaged = false
    @Environment(\.searchOrigin) private var searchOrigin
    @Environment(Router.self) private var router

    private var title: String {
        switch item {
        case .track(let t): t.title
        case .media(let m): m.title
        }
    }

    /// Who it's by, and what YouTube counts for it ("Daft Punk • 1.2B views").
    private var subtitle: String {
        switch item {
        case .track(let t): ([t.artistLine] + [t.plays].compactMap { $0 }).joined(separator: " • ")
        case .media(let m): m.subtitle
        }
    }

    private var thumbnail: URL? {
        switch item {
        case .track(let t): t.thumbnail
        case .media(let m): m.thumbnail
        }
    }

    private var isArtist: Bool {
        if case .media(let m) = item { return m.target.kind == .artist }
        return false
    }

    /// The artists in the subtitle, each clickable on its own.
    private var subtitleArtists: [ArtistRef] {
        switch item {
        case .track(let t): t.artists.filter { $0.browseId != nil }
        case .media(let m): m.artists ?? []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(url: thumbnail, size: size, cornerRadius: 6, circle: isArtist)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
                .overlay(alignment: .bottomTrailing) {
                    // Only while hovering: a hidden button still costs a hover region and a shadow.
                    if canPlay, engaged {
                        PlayCircleButton(size: 46, action: play)
                            .padding(8)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                }
                .animation(.spring(duration: 0.25), value: engaged)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                // Artists: their audience when YouTube gives it ("23.3M monthly audience").
                LinkedSubtitle(text: isArtist && subtitle.isEmpty ? String(localized: "Artist") : subtitle,
                               artists: isArtist ? [] : subtitleArtists, interactive: engaged)
            }
            .frame(width: size, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover($hovering, engaged: $engaged)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .menuOnRightClick(hovering: hovering) {
            switch item {
            case .track(let track): TrackMenuEntries.make(for: track)
            case .media(let media): MediaMenuEntries.make(media)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityAction(named: "Play") { play() }
    }

    private var canPlay: Bool {
        switch item {
        case .track: true
        case .media(let m): m.target.kind != .other
        }
    }

    private func open() {
        if searchOrigin { RecentSearches.add(item) }
        switch item {
        case .track: play()
        case .media(let m): router.open(m.target)
        }
    }

    private func play() {
        if searchOrigin { RecentSearches.add(item) }
        switch item {
        case .track(let track):
            if siblings.count > 1, let index = siblings.firstIndex(of: track) {
                PlayerController.shared.play(siblings, startAt: index)
            } else {
                PlayerController.shared.playRadio(from: track)
            }
        case .media(let m):
            PlayerController.shared.playCollection(m.target, playlistId: m.playlistId)
        }
    }
}

// MARK: - Shelves

struct ShelfView: View {
    var shelf: Shelf
    var onLoadMore: (() -> Void)?
    @Environment(Router.self) private var router
    @State private var width = ShelfView.lastWidth
    /// Which card (or Quick picks column) is at the left edge of a shelf scrolled sideways.
    /// Only whole steps are stored: tracking the raw offset re-rendered the shelf every frame.
    @State private var leadingIndex = 0

    /// Shared so a shelf scrolling into view starts at the right size, not empty for a frame.
    @MainActor static var lastWidth: CGFloat = 0

    private var filtered: Shelf {
        var copy = shelf
        copy.items = ContentFilter.shared.filter(shelf.items)
        return copy
    }

    /// Cards that fit in one row (each is its artwork plus 12pt padding on both sides).
    private var fitting: Int { max(1, Int(width / (MediaCard.defaultSize + 24))) }

    struct Pager {
        var previous: () -> Void
        var next: () -> Void
        var canGoPrevious: Bool
        var canGoNext: Bool
    }

    /// ‹ › for a shelf with more than fits: a page (what fits on screen) at a time.
    private func pager(for shelf: Shelf, proxy: ScrollViewProxy) -> Pager? {
        switch shelf.style {
        case .carousel where shelf.items.count > fitting:
            let ids = shelf.items.map(\.id)
            let current = min(max(0, leadingIndex), ids.count - 1)
            let lastStart = max(0, ids.count - fitting)
            return Pager(
                previous: { withAnimation(.snappy) { proxy.scrollTo(ids[max(0, current - fitting)], anchor: .leading) } },
                next: { withAnimation(.snappy) { proxy.scrollTo(ids[min(lastStart, current + fitting)], anchor: .leading) } },
                canGoPrevious: current > 0,
                canGoNext: current < lastStart
            )
        case .rows:
            let columns = QuickPicksGrid.layout(count: shelf.tracks.count, width: width).columns
            let visible = QuickPicksGrid.columnsThatFit(width)
            guard columns > visible else { return nil }
            let current = min(max(0, leadingIndex), columns - 1)
            let lastStart = max(0, columns - visible)
            return Pager(
                previous: { withAnimation(.snappy) { proxy.scrollTo(QuickPicksGrid.columnID(max(0, current - visible)), anchor: .leading) } },
                next: { withAnimation(.snappy) { proxy.scrollTo(QuickPicksGrid.columnID(min(lastStart, current + visible)), anchor: .leading) } },
                canGoPrevious: current > 0,
                canGoNext: current < lastStart
            )
        default:
            return nil
        }
    }

    /// YouTube's page for the shelf if it has one, else our own grid of its items.
    private var showAll: (() -> Void)? {
        if let more = shelf.moreTarget { return { router.open(more) } }
        if shelf.style == .carousel, shelf.items.count > fitting { return { router.navigate(.shelf(shelf)) } }
        if shelf.style == .rows, shelf.items.count > QuickPicksGrid.columnsThatFit(width) * 4 {
            return { router.navigate(.shelf(shelf)) }
        }
        return nil
    }

    var body: some View {
        // Hidden songs and artists (AI, explicit, ones you hid) never show in shelves.
        let shelf = filtered
        // Once per render, not once per card (each card used to rebuild the whole list).
        let tracks = shelf.tracks
        ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: 6) {
            if let title = shelf.title {
                let paging = pager(for: shelf, proxy: proxy)
                SectionHeader(title: title, label: shelf.label, showAll: showAll,
                              onPrevious: paging?.previous, onNext: paging?.next,
                              canGoPrevious: paging?.canGoPrevious ?? false, canGoNext: paging?.canGoNext ?? false)
                    .onAppear { Bench.event("shelf \(shelf.style) \(shelf.items.count) \(title)") }
                    .padding(.horizontal, 12)
            }
            switch shelf.style {
            case .carousel:
                // Swipe sideways with the trackpad (or use ‹ ›). Lazy, so only the cards on screen
                // are built; cards size so a whole number of them fills the row, and paging snaps to them.
                let cardSize = width > 0 ? (width / CGFloat(fitting)).rounded(.down) - 24 : MediaCard.defaultSize
                // Free scrolling, like the trackpad expects: snapping to cards fought its momentum.
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 0) {
                        ForEach(shelf.items) { MediaCard(item: $0, size: cardSize, siblings: tracks).id($0.id) }
                    }
                }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: Int.self) { geo in
                    Int((geo.contentOffset.x / max(1, cardSize + 24)).rounded())
                } action: { _, index in
                    leadingIndex = index
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
                    width = new
                    ShelfView.lastWidth = new
                }
            case .rows:
                QuickPicksGrid(tracks: tracks, width: width) { leadingIndex = $0 }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
                        width = new
                        ShelfView.lastWidth = new
                    }
            case .categories:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                    ForEach(shelf.items) { item in
                        if case .media(let media) = item { CategoryTile(item: media) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            case .grid:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 0, alignment: .top)], spacing: 8) {
                    ForEach(shelf.items) { MediaCard(item: $0, size: 156, siblings: tracks) }
                }
            case .list:
                if shelf.items.allSatisfy({ $0.track != nil }) {
                    TrackList(tracks: tracks, onLoadMore: onLoadMore)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(shelf.items) { item in
                            if case .track(let track) = item {
                                TrackRow(track: track, index: 0, numbered: false) { PlayerController.shared.playRadio(from: track) }
                            } else if case .media(let media) = item {
                                MediaRow(item: media)
                            }
                        }
                    }
                }
            }
        }
        // Grids need the full width to lay out their columns.
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Coloured mood/genre tile ("Browse all").
struct CategoryTile: View {
    var item: MediaItem
    @State private var hovering = false
    @Environment(Router.self) private var router

    private var color: Color {
        guard let argb = item.color else { return .brand }
        return Color(red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255, blue: Double(argb & 0xFF) / 255)
    }

    var body: some View {
        Text(item.title)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(alignment: .bottomTrailing) {
                // A tilted block in the corner.
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.mix(with: .white, by: 0.3))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(25))
                    .offset(x: 14, y: 6)
                    .shadow(color: .black.opacity(0.3), radius: 6)
            }
            .background(color.mix(with: .black, by: 0.2))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .brightness(hovering ? 0.05 : 0)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
            .onTapGesture { router.open(item.target) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { router.open(item.target) }
    }
}

/// Multi-column song grid ("Quick picks").
/// "Quick picks": columns of four songs, as many columns as fit (the rest behind "Show all").
/// Not a sideways scroll view: those were costly to build and to hit-test while scrolling.
struct QuickPicksGrid: View {
    static let columnWidth: CGFloat = 400
    static func columnsThatFit(_ width: CGFloat) -> Int { max(1, Int((width + 16) / (columnWidth + 16))) }

    /// Columns of up to four songs, 400 pt wide, scrolling sideways when there are more than fit.
    /// A short list instead spreads over the width with fewer songs per column (four songs: two
    /// columns of two), rather than one narrow column beside an empty row.
    static func layout(count: Int, width: CGFloat) -> (rows: Int, columns: Int, columnWidth: CGFloat) {
        let fitting = columnsThatFit(width)
        let rows = min(4, max(min(2, count), (count + fitting - 1) / fitting))
        let columns = max(1, (count + rows - 1) / max(1, rows))
        guard columns <= fitting, width > 0 else { return (rows, columns, columnWidth) }
        let stretched = ((width - 16 * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        return (rows, columns, max(columnWidth, stretched))
    }
    /// Scroll ids for the columns (strings, so they can't collide with other ids on the page).
    static func columnID(_ column: Int) -> String { "quickpicks-\(column)" }

    var tracks: [Track]
    var width: CGFloat
    /// The column now at the left edge, as you scroll sideways.
    var onLeadingColumn: ((Int) -> Void)? = nil

    var body: some View {
        let layout = Self.layout(count: tracks.count, width: width)
        let rows = layout.rows
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(0..<layout.columns, id: \.self) { column in
                    VStack(spacing: 2) {
                        ForEach(column * rows..<min(tracks.count, column * rows + rows), id: \.self) { index in
                            TrackRow(track: tracks[index], index: index, showAlbum: false, numbered: false, compact: true) {
                                PlayerController.shared.playRadio(from: tracks[index])
                            }
                        }
                    }
                    .frame(width: layout.columnWidth, alignment: .top)
                    .id(Self.columnID(column))
                }
            }
        }
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: Int.self) { geo in
            Int((geo.contentOffset.x / (layout.columnWidth + 16)).rounded())
        } action: { _, column in
            onLeadingColumn?(column)
        }
        .frame(maxWidth: .infinity, minHeight: CGFloat(rows) * 56 + CGFloat(rows - 1) * 2, alignment: .topLeading)
    }
}

struct MediaRow: View {
    var item: MediaItem
    @State private var hovering = false
    @Environment(Router.self) private var router

    var body: some View {
        let player = PlayerController.shared
        let playingThis = player.isPlaying(from: item.target)
        HStack(spacing: 12) {
            ArtworkView(url: item.thumbnail, size: 48, cornerRadius: 4, circle: item.target.kind == .artist)
                .overlay {
                    CoverPlayOverlay(visible: hovering && item.target.kind != .other, playing: playingThis && player.isPlaying,
                                     circle: item.target.kind == .artist) {
                        if playingThis { player.togglePlayPause() } else { player.playCollection(item.target, playlistId: item.playlistId) }
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 15)).foregroundStyle(playingThis ? Theme.accent : Theme.text).lineLimit(1)
                LinkedSubtitle(text: item.subtitle, artists: item.artists ?? [], interactive: hovering, lines: 1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.text.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { router.open(item.target) }
        .menuOnRightClick(hovering: hovering) { MediaMenuEntries.make(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(item.subtitle)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { router.open(item.target) }
    }
}

struct LoadingView: View {
    var body: some View {
        SkeletonRows().padding(.horizontal, 28)
    }
}

struct ErrorView: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

/// Fades content in when it first appears (page loads).
struct AppearTransition: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear { withAnimation(.easeOut(duration: 0.25)) { shown = true } }
    }
}

extension View {
    func appearTransition() -> some View { modifier(AppearTransition()) }
}

/// "Show all" for a shelf with no YouTube page of its own: every item, in a grid.
struct ShelfPage: View {
    var shelf: Shelf

    private var filtered: Shelf {
        var copy = shelf
        copy.items = ContentFilter.shared.filter(shelf.items)
        return copy
    }

    var body: some View {
        let shelf = filtered
        let tracks = shelf.tracks
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(shelf.title ?? "")
                    .font(.system(size: 32, weight: .bold))
                    .padding(.horizontal, 12)
                if shelf.style == .rows {
                    TrackList(tracks: tracks, showAlbum: true, numbered: false)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: MediaCard.defaultSize + 24), spacing: 0, alignment: .top)], spacing: 8) {
                        ForEach(shelf.items) { MediaCard(item: $0, siblings: tracks) }
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding - 12)
            .padding(.top, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Clicking outside a field

/// Ends typing in a field when you click anywhere else in the window (as in Safari): the field
/// lets go of the keyboard (so Space plays again) and `onOutside` runs (close a dropdown,
/// collapse an empty search). The click still reaches what it was aimed at. `inside` adds areas
/// that count as the field's own (its dropdown). Listens only while `isActive`.
struct EndEditingOnOutsideClick: ViewModifier {
    var isActive: Bool
    var inside: [CGRect] = []
    var onOutside: () -> Void
    @State private var watcher = OutsideClickWatcher()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { watcher.frame = $0 }
            .onChange(of: isActive, initial: true) { _, active in
                // The latest action each time it starts listening.
                watcher.onOutside = onOutside
                if active { watcher.start() } else { watcher.stop() }
            }
            .onChange(of: inside, initial: true) { _, areas in watcher.inside = areas }
            .onDisappear { watcher.stop() }
    }
}

@MainActor
final class OutsideClickWatcher {
    var frame: CGRect = .zero
    var inside: [CGRect] = []
    var onOutside: () -> Void = {}
    private var monitor: Any?

    /// The field's own window (the key window when it started typing): clicks in any other window
    /// (a sheet, a menu, the mini player) are none of its business.
    private weak var window: NSWindow?

    func start() {
        guard monitor == nil else { return }
        window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        // SwiftUI's global frames count from the window's top left, title bar included (checked
        // against what's drawn, with and without a separate title bar).
        let location = event.locationInWindow
        let point = CGPoint(x: location.x, y: window.frame.height - location.y)
        guard !frame.contains(point), !inside.contains(where: { $0.contains(point) }) else { return }
        window.makeFirstResponder(nil)
        onOutside()
    }
}

extension View {
    func endEditingOnOutsideClick(isActive: Bool, inside: [CGRect] = [], onOutside: @escaping () -> Void = {}) -> some View {
        modifier(EndEditingOnOutsideClick(isActive: isActive, inside: inside, onOutside: onOutside))
    }
}
