use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ArtistRef {
    pub name: String,
    pub browse_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct AlbumRef {
    pub name: String,
    pub browse_id: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum LikeStatus {
    Like,
    Dislike,
    Indifferent,
}

impl LikeStatus {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "LIKE" => Some(Self::Like),
            "DISLIKE" => Some(Self::Dislike),
            "INDIFFERENT" => Some(Self::Indifferent),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Track {
    pub video_id: String,
    pub title: String,
    pub artists: Vec<ArtistRef>,
    pub album: Option<AlbumRef>,
    /// Seconds.
    pub duration: Option<f64>,
    pub thumbnail: Option<String>,
    pub is_video: bool,
    /// "1.2B plays" on artist pages.
    pub plays: Option<String>,
    pub is_explicit: bool,
    /// Whether it was in Liked Music when YouTube sent it.
    pub like_status: Option<LikeStatus>,
    /// The song's slot in a playlist (`playlistSetVideoId`): needed to remove or move it.
    pub set_video_id: Option<String>,
    /// Token that removes this play from your listening history (history page only).
    pub history_token: Option<String>,
}

impl Track {
    pub fn artist_line(&self) -> String {
        if self.artists.is_empty() {
            "Unknown artist".to_owned()
        } else {
            self.artists.iter().map(|a| a.name.as_str()).collect::<Vec<_>>().join(", ")
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PageKind {
    Album,
    Playlist,
    Artist,
    /// A podcast show and one of its episodes.
    Podcast,
    Episode,
    #[default]
    Other,
}

impl PageKind {
    pub fn from_page_type(page_type: Option<&str>) -> Self {
        match page_type {
            Some("MUSIC_PAGE_TYPE_ALBUM" | "MUSIC_PAGE_TYPE_AUDIOBOOK") => Self::Album,
            Some("MUSIC_PAGE_TYPE_PLAYLIST") => Self::Playlist,
            Some("MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE") => Self::Podcast,
            Some("MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE") => Self::Episode,
            Some("MUSIC_PAGE_TYPE_ARTIST" | "MUSIC_PAGE_TYPE_USER_CHANNEL" | "MUSIC_PAGE_TYPE_LIBRARY_ARTIST") => Self::Artist,
            _ => Self::Other,
        }
    }
}

/// Something you can open: an album, playlist or artist page.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct BrowseTarget {
    pub browse_id: String,
    pub kind: PageKind,
    pub title: String,
    pub params: Option<String>,
}

/// A non-track item in a shelf (album, playlist, artist card).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MediaItem {
    pub target: BrowseTarget,
    pub subtitle: String,
    pub thumbnail: Option<String>,
    /// Playlist id to start playback straight from the card's play button.
    pub playlist_id: Option<String>,
    /// ARGB colour for genre/mood tiles (they have no artwork).
    pub color: Option<u32>,
    /// The artists named in the subtitle, so each can be clicked.
    pub artists: Vec<ArtistRef>,
}

impl MediaItem {
    pub fn title(&self) -> &str {
        &self.target.title
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum ShelfItem {
    Track(Track),
    Media(MediaItem),
}

impl ShelfItem {
    pub fn track(&self) -> Option<&Track> {
        match self {
            ShelfItem::Track(t) => Some(t),
            ShelfItem::Media(_) => None,
        }
    }

    pub fn media(&self) -> Option<&MediaItem> {
        match self {
            ShelfItem::Media(m) => Some(m),
            ShelfItem::Track(_) => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ShelfStyle {
    List,
    Carousel,
    /// A horizontally scrolling grid of song rows ("Quick picks").
    Rows,
    Grid,
    Categories,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Shelf {
    pub title: Option<String>,
    /// Small line above the title ("Made for", "Non-stop music based on…").
    pub label: Option<String>,
    pub style: ShelfStyle,
    pub items: Vec<ShelfItem>,
    /// Continuation token to load more items into this shelf.
    pub continuation: Option<String>,
    /// Endpoint behind the shelf title ("More" link), if any.
    pub more_target: Option<BrowseTarget>,
    /// The actual contents of a playlist (vs. suggestions shown under an empty one).
    pub is_playlist_contents: bool,
}

impl Shelf {
    pub fn new(style: ShelfStyle, items: Vec<ShelfItem>) -> Self {
        Shelf {
            title: None,
            label: None,
            style,
            items,
            continuation: None,
            more_target: None,
            is_playlist_contents: false,
        }
    }

    pub fn tracks(&self) -> Vec<&Track> {
        self.items.iter().filter_map(ShelfItem::track).collect()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct PageHeader {
    pub title: String,
    pub subtitle: Option<String>,
    pub second_subtitle: Option<String>,
    pub description: Option<String>,
    pub thumbnail: Option<String>,
    pub artists: Vec<ArtistRef>,
    /// Playlist owner (from the header's avatar "facepile").
    pub owner: Option<ArtistRef>,
    pub owner_avatar: Option<String>,
    /// The playable playlist behind an album or playlist page.
    pub playlist_id: Option<String>,
    /// Whether the album/playlist is saved in the signed-in account's library.
    pub in_library: Option<bool>,
    /// Artist pages: the channel to subscribe to and whether you are.
    pub channel_id: Option<String>,
    pub subscribed: Option<bool>,
    /// Artist pages: YouTube's artist mix and shuffle playlists.
    pub radio_playlist_id: Option<String>,
    pub shuffle_playlist_id: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct BrowsePage {
    pub header: Option<PageHeader>,
    pub shelves: Vec<Shelf>,
    /// Continuation for appending more shelves (home / library feeds).
    pub continuation: Option<String>,
    pub kind: PageKind,
    /// Mood chips at the top of Home ("Energize", "Relax"…).
    pub chips: Vec<SearchFilter>,
}

impl BrowsePage {
    pub fn is_collection(&self) -> bool {
        matches!(self.kind, PageKind::Album | PageKind::Playlist | PageKind::Podcast)
    }

    /// The shelf holding the page's own tracks. For playlists only the real contents count: an
    /// empty playlist also carries a "suggestions" list that must not be mistaken for it.
    pub fn main_shelf(&self) -> Option<&Shelf> {
        if matches!(self.kind, PageKind::Playlist | PageKind::Podcast) {
            self.shelves.iter().find(|s| s.is_playlist_contents)
        } else {
            self.shelves.iter().find(|s| s.style == ShelfStyle::List && !s.tracks().is_empty())
        }
    }

    pub fn main_tracks(&self) -> Vec<&Track> {
        self.main_shelf().map(Shelf::tracks).unwrap_or_default()
    }

    /// Album tracks come without artwork/artist/album info; inherit it from the page header.
    pub fn fill_track_context(&mut self, target: &BrowseTarget) {
        let Some(header) = self.header.clone() else { return };
        for shelf in self.shelves.iter_mut().filter(|s| s.style == ShelfStyle::List) {
            for item in shelf.items.iter_mut() {
                let ShelfItem::Track(track) = item else { continue };
                if track.thumbnail.is_none() {
                    track.thumbnail = header.thumbnail.clone();
                }
                if target.kind == PageKind::Album {
                    if (track.artists.is_empty() || track.artists.iter().all(|a| a.browse_id.is_none()))
                        && !header.artists.is_empty()
                    {
                        track.artists = header.artists.clone();
                    }
                    if track.album.is_none() {
                        track.album = Some(AlbumRef { name: header.title.clone(), browse_id: Some(target.browse_id.clone()) });
                    }
                }
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SearchFilter {
    pub title: String,
    pub params: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct SearchResults {
    pub top: Option<ShelfItem>,
    pub top_subtitle: Option<String>,
    pub items: Vec<ShelfItem>,
    pub filters: Vec<SearchFilter>,
    pub continuation: Option<String>,
}

/// YouTube Music's autocomplete: query completions, then the top artist, songs and albums.
#[derive(Clone, Debug, Default)]
pub struct SearchSuggestions {
    pub queries: Vec<String>,
    pub items: Vec<ShelfItem>,
}

#[derive(Clone, Debug, Default)]
pub struct RadioResult {
    pub tracks: Vec<Track>,
    pub continuation: Option<String>,
    /// The radio's tuning chips, and which one it's playing (none: not offered).
    pub tuners: Vec<RadioTuner>,
    pub selected_tuner: Option<String>,
}

/// YouTube Music's chips above a radio's queue ("Popular", "Discover", "Deep cuts"…), each a
/// differently tuned version of the same radio.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RadioTuner {
    pub title: String,
    pub playlist_id: String,
    pub params: Option<String>,
}
