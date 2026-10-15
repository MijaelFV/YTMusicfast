import Foundation

struct ArtistRef: Hashable, Sendable, Codable {
    var name: String
    var browseId: String?
}

struct AlbumRef: Hashable, Sendable, Codable {
    var name: String
    var browseId: String?
}

struct Track: Identifiable, Hashable, Sendable, Codable {
    var videoId: String
    var title: String
    var artists: [ArtistRef] = []
    var album: AlbumRef?
    var duration: TimeInterval?
    var thumbnail: URL?
    var isVideo = false
    /// "1.2B plays" on artist pages.
    var plays: String?
    /// Optional so tracks saved by older versions (recents, the restored queue) still decode.
    var isExplicit: Bool?
    /// Whether it was in Liked Music when YouTube sent it; `PlayerController.isLiked` has the live answer.
    var likeStatus: LikeStatus?
    /// The song's slot in a playlist (`playlistSetVideoId`): needed to remove or move it.
    var setVideoId: String?
    /// Token that removes this play from your listening history (history page only).
    var historyToken: String?
    /// A file on this Mac (Local Files) instead of a YouTube song.
    var localPath: String?

    var isLocal: Bool { localPath != nil }

    var id: String { videoId }

    var artistLine: String {
        artists.isEmpty ? "Unknown artist" : artists.map(\.name).joined(separator: ", ")
    }
}

enum PageKind: String, Hashable, Sendable, Codable {
    case album, playlist, artist, other
    /// A podcast show and one of its episodes.
    case podcast, episode

    init(pageType: String?) {
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK": self = .album
        case "MUSIC_PAGE_TYPE_PLAYLIST": self = .playlist
        case "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE": self = .podcast
        case "MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE": self = .episode
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST": self = .artist
        default: self = .other
        }
    }
}

/// Something you can open: an album, playlist or artist page.
struct BrowseTarget: Hashable, Sendable, Codable {
    var browseId: String
    var kind: PageKind
    var title: String
    var params: String?
}

/// A non-track item in a shelf (album, playlist, artist card).
struct MediaItem: Identifiable, Hashable, Sendable, Codable {
    var target: BrowseTarget
    var subtitle: String
    var thumbnail: URL?
    /// Playlist id to start playback straight from the card's play button.
    var playlistId: String?
    /// ARGB colour for genre/mood tiles (they have no artwork).
    var color: UInt32?
    /// The artists named in the subtitle, so each can be clicked (optional: older saved pages
    /// don't have them).
    var artists: [ArtistRef]?

    var id: String { target.params.map { "\(target.browseId)|\($0)" } ?? target.browseId }
    var title: String { target.title }
    /// The same playlist, album or artist however it was opened: YouTube adds page parameters
    /// from some places (e.g. your own playlists), which make `id` differ. Genre and mood pages
    /// do differ by parameters, so they keep them.
    var collectionId: String { target.kind == .other ? id : target.browseId }
}

enum ShelfItem: Identifiable, Hashable, Sendable, Codable {
    case track(Track)
    case media(MediaItem)

    var id: String {
        switch self {
        case .track(let t): "t:\(t.videoId)"
        case .media(let m): "m:\(m.id)"
        }
    }

    var track: Track? {
        if case .track(let t) = self { return t }
        return nil
    }
}

struct Shelf: Identifiable, Hashable, Sendable, Codable {
    /// `rows` is a horizontally scrolling grid of song rows ("Quick picks").
    enum Style: Hashable, Sendable, Codable { case list, carousel, rows, grid, categories }

    var id = UUID()
    var title: String?
    /// Small line above the title ("Made for", "Non-stop music based on…").
    var label: String?
    var style: Style
    var items: [ShelfItem]
    /// Continuation token to load more items into this shelf.
    var continuation: String?
    /// Endpoint behind the shelf title ("More" link), if any.
    var moreTarget: BrowseTarget?
    /// The actual contents of a playlist (vs. suggestions shown under an empty one).
    var isPlaylistContents = false

    var tracks: [Track] { items.compactMap(\.track) }
}

struct PageHeader: Hashable, Sendable, Codable {
    var title: String
    var subtitle: String?
    var secondSubtitle: String?
    var description: String?
    var thumbnail: URL?
    var artists: [ArtistRef] = []
    /// Playlist owner (from the header's avatar "facepile").
    var owner: ArtistRef?
    var ownerAvatar: URL?
    /// The playable playlist behind an album or playlist page (`OLAK5uy_…`, `PL…`, `RDCLAK…`).
    var playlistId: String?
    /// Whether the album/playlist is saved in the signed-in account's library (nil: no such button).
    var inLibrary: Bool?
    /// Artist pages: the channel to subscribe to (not always the page's browse id) and whether you are.
    var channelId: String?
    var subscribed: Bool?
    /// Artist pages: YouTube's artist mix and shuffle playlists.
    var radioPlaylistId: String?
    var shufflePlaylistId: String?
}

struct BrowsePage: Sendable, Codable {
    var header: PageHeader?
    var shelves: [Shelf] = []
    /// Continuation for appending more shelves (home / library feeds).
    var continuation: String?
    /// What kind of page this is (set by `MusicAPI.browse`).
    var kind: PageKind = .other
    /// Mood chips at the top of Home ("Energize", "Relax"…).
    var chips: [SearchFilter] = []
    /// Charts: the countries it can show, and which one this is.
    var countries: [ChartCountry] = []
    var selectedCountry: String?

    /// Albums, playlists and podcasts: pages built around one list of songs or episodes.
    var isCollection: Bool { [.album, .playlist, .podcast].contains(kind) }

    /// The shelf holding the page's own tracks. For playlists only the real contents count —
    /// an empty playlist also carries a "suggestions" list that must not be mistaken for it.
    var mainShelf: Shelf? {
        kind == .playlist || kind == .podcast
            ? shelves.first(where: \.isPlaylistContents)
            : shelves.first { $0.style == .list && !$0.tracks.isEmpty }
    }

    /// The primary track list of an album/playlist page.
    var mainTracks: [Track] { mainShelf?.tracks ?? [] }
}

struct SearchFilter: Identifiable, Hashable, Sendable, Codable {
    var title: String
    var params: String?
    var id: String { title }
}

struct SearchResults: Sendable {
    var top: ShelfItem?
    var topSubtitle: String?
    var items: [ShelfItem] = []
    var filters: [SearchFilter] = []
    var continuation: String?
}

/// YouTube Music's autocomplete: query completions, then the top artist, songs and albums themselves.
struct SearchSuggestions: Sendable {
    var queries: [String] = []
    var items: [ShelfItem] = []
}

struct RadioResult: Sendable {
    var tracks: [Track]
    var continuation: String?
    /// The radio's tuning chips, and which one it's playing (nil: none offered).
    var tuners: [RadioTuner] = []
    var selectedTuner: String?
}

/// YouTube Music's chips above a radio's queue — "Popular", "Discover", "Deep cuts", "Party",
/// "2010s"… — each a differently tuned version of the same radio.
struct RadioTuner: Identifiable, Hashable, Sendable {
    var title: String
    var playlistId: String
    var params: String?
    var id: String { title }
}

enum LikeStatus: String, Sendable, Codable {
    case like = "LIKE", dislike = "DISLIKE", indifferent = "INDIFFERENT"
}

/// A YouTube comment on the playing song or video.
struct Comment: Identifiable, Hashable, Sendable {
    var id: String
    var author: String
    var authorAvatar: URL?
    var text: String
    var published: String
    var likes: String?
    var replyCount: Int
    /// Loads this comment's replies.
    var repliesToken: String?
    /// The video's own channel or the artist.
    var isCreator = false
}

struct CommentPage: Sendable {
    var comments: [Comment] = []
    var next: String?
    /// "210,842 Comments".
    var total: String?
    /// Top / Newest, each with its own first-page token.
    var sorts: [SearchFilter] = []
    /// Present when signed in and commenting is allowed.
    var createParams: String?
}

/// A chapter of a long video or podcast episode.
struct Chapter: Hashable, Sendable {
    var title: String
    var start: TimeInterval
}

/// Extra details about a song only the regular YouTube watch page has.
struct WatchExtras: Sendable {
    var chapters: [Chapter] = []
    /// First page of comments; nil when they're turned off.
    var commentsToken: String?
}

/// A country Charts can show.
struct ChartCountry: Hashable, Sendable, Identifiable, Codable {
    var code: String
    var name: String
    var id: String { code }
}

/// One role on YouTube Music's "Song credits" ("Produced by" → names).
struct CreditRole: Hashable, Sendable {
    var role: String
    var names: [String]
}

struct PlaylistOption: Identifiable, Hashable, Sendable {
    var playlistId: String
    var title: String
    var thumbnail: URL?
    var id: String { playlistId }
}
