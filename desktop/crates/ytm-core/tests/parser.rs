//! Parsers run against the same captured InnerTube responses as the Mac app's tests
//! (`YTMusicfastTests/Fixtures`). When YouTube changes its layout, refresh a fixture and both
//! suites show exactly what broke.

use serde_json::Value;
use ytm_core::parser;
use ytm_core::*;

fn fixture(name: &str) -> Value {
    let path = format!("{}/../../../YTMusicfastTests/Fixtures/{name}.json", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_slice(&std::fs::read(&path).unwrap_or_else(|_| panic!("missing fixture {name}"))).unwrap()
}

#[test]
fn search_top_result_and_filters() {
    let results = parser::search(&fixture("search"));
    let Some(ShelfItem::Media(top)) = &results.top else { panic!("expected an artist as the top result") };
    assert_eq!(top.title(), "Daft Punk");
    assert_eq!(top.target.kind, PageKind::Artist);
    assert!(results.items.len() > 10);
    let titles: Vec<&str> = results.filters.iter().map(|f| f.title.as_str()).collect();
    for wanted in ["All", "Songs", "Albums", "Artists"] {
        assert!(titles.contains(&wanted), "missing filter {wanted}");
    }
    assert!(results.filters[1..].iter().all(|f| f.params.is_some()));
}

#[test]
fn song_search_parses_artists_albums_and_durations() {
    let results = parser::search(&fixture("songs"));
    let tracks: Vec<&Track> = results.items.iter().filter_map(ShelfItem::track).collect();
    assert!(tracks.len() >= 10);
    let first = tracks[0];
    assert_eq!(first.artists[0].name, "Daft Punk");
    assert!(first.artists[0].browse_id.is_some());
    assert!(first.album.as_ref().and_then(|a| a.browse_id.as_deref()).is_some_and(|id| id.starts_with("MPRE")));
    assert!(first.duration.unwrap_or(0.0) > 60.0);
    assert!(tracks.iter().all(|t| !t.is_video));
}

#[test]
fn album_page() {
    let mut page = parser::page(&fixture("album"));
    let target = BrowseTarget { browse_id: "MPREb_K8qWMWVqXGi".into(), kind: PageKind::Album, title: String::new(), params: None };
    page.fill_track_context(&target);
    let header = page.header.as_ref().unwrap();
    assert_eq!(header.title, "Random Access Memories");
    assert_eq!(header.artists[0].name, "Daft Punk");
    assert!(header.thumbnail.is_some());
    let tracks = page.main_tracks();
    assert_eq!(tracks.len(), 13);
    // Album rows lack art/album info; it must be inherited from the header.
    assert!(tracks.iter().all(|t| t.thumbnail.is_some() && t.album.as_ref().unwrap().name == "Random Access Memories"));
    assert!(tracks.iter().all(|t| t.duration.unwrap_or(0.0) > 0.0));
}

#[test]
fn artist_page() {
    let page = parser::page(&fixture("artist"));
    assert_eq!(page.header.as_ref().unwrap().title, "Daft Punk");
    let top_songs = page.shelves.iter().find(|s| s.style == ShelfStyle::List).unwrap();
    assert_eq!(top_songs.tracks().len(), 5);
    let carousels: Vec<&Shelf> = page.shelves.iter().filter(|s| s.style == ShelfStyle::Carousel).collect();
    assert!(carousels.len() >= 3);
    assert!(carousels
        .iter()
        .any(|s| s.items.iter().any(|i| i.media().is_some_and(|m| m.target.kind == PageKind::Album))));
}

#[test]
fn playlist_page() {
    let page = parser::page(&fixture("playlist"));
    let header = page.header.as_ref().unwrap();
    assert!(!header.title.is_empty());
    assert!(header.second_subtitle.as_deref().unwrap().contains("40 tracks"));
    assert_eq!(page.main_tracks().len(), 40);
    // All 40 tracks are inline; the page continuation loads "Related playlists".
    assert!(page.shelves.iter().find(|s| s.style == ShelfStyle::List).unwrap().continuation.is_none());
    assert!(page.continuation.is_some());
}

#[test]
fn playlist_rows_carry_like_status() {
    let page = parser::page(&fixture("playlist"));
    let tracks = page.main_tracks();
    assert!(!tracks.is_empty());
    assert!(tracks.iter().all(|t| t.like_status.is_some()));
}

#[test]
fn explicit_badge() {
    // The song search fixture has exactly one explicit song.
    let results = parser::search(&fixture("songs"));
    assert_eq!(results.items.iter().filter_map(ShelfItem::track).filter(|t| t.is_explicit).count(), 1);
}

#[test]
fn long_playlist_loads_more_tracks() {
    // Captured from a public 500-song playlist: later batches arrive as bare rows.
    let page = parser::page(&fixture("playlist-continuation"));
    let shelf = page.shelves.iter().find(|s| s.style == ShelfStyle::List).unwrap();
    assert_eq!(shelf.tracks().len(), 5);
    assert!(shelf.continuation.is_some());
}

#[test]
fn playlist_contents_come_from_the_playlist_shelf_only() {
    let mut page = parser::page(&fixture("playlist"));
    page.kind = PageKind::Playlist;
    assert!(page.main_shelf().unwrap().is_playlist_contents);
    assert_eq!(page.main_tracks().len(), 40);
    // A playlist page with only a suggestions list has no contents of its own.
    for shelf in page.shelves.iter_mut() {
        shelf.is_playlist_contents = false;
    }
    assert!(page.main_tracks().is_empty());
}

#[test]
fn home_feed() {
    let page = parser::page(&fixture("home"));
    assert!(page.shelves.len() >= 2);
    assert!(page.shelves.iter().any(|s| s.style == ShelfStyle::Rows && s.tracks().len() >= 10));
    assert!(page.shelves.iter().any(|s| s.style == ShelfStyle::Carousel));
    assert!(page.shelves.iter().all(|s| s.title.is_some()));
}

#[test]
fn moods_and_genres_tiles() {
    let page = parser::page(&fixture("moods"));
    assert!(!page.header.as_ref().unwrap().title.is_empty());
    let grids: Vec<&Shelf> = page.shelves.iter().filter(|s| s.style == ShelfStyle::Categories).collect();
    assert_eq!(grids.len(), 2);
    let tiles: Vec<&MediaItem> = grids.iter().flat_map(|s| s.items.iter().filter_map(ShelfItem::media)).collect();
    assert_eq!(tiles.len(), 45);
    assert!(tiles.iter().all(|t| t.color.is_some() && t.target.params.is_some()));
}

#[test]
fn search_songs_inherit_top_artist() {
    let results = parser::search(&fixture("search"));
    let tracks: Vec<&Track> = results.items.iter().filter_map(ShelfItem::track).collect();
    assert!(!tracks.is_empty());
    assert!(tracks.iter().all(|t| !t.artists.is_empty()));
}

#[test]
fn radio_queue() {
    let radio = parser::radio(&fixture("next"));
    assert_eq!(radio.tracks.len(), 50);
    assert!(radio.continuation.is_some());
    assert_eq!(radio.tracks[0].video_id, "5NV6Rdv1a3I");
    assert!(radio.tracks.iter().all(|t| !t.artists.is_empty() && t.duration.is_some()));
}

#[test]
fn radio_tuners() {
    let radio = parser::radio(&fixture("radio-tuners"));
    assert!(radio.tuners.len() > 1);
    assert!(radio.selected_tuner.is_some());
}

#[test]
fn suggestions() {
    let suggestions = parser::suggestions(&fixture("suggestions"));
    assert!(!suggestions.queries.is_empty());
}

#[test]
fn durations() {
    assert_eq!(parser::duration("4:09"), Some(249.0));
    assert_eq!(parser::duration("1:02:03"), Some(3723.0));
    assert_eq!(parser::duration("0:05"), Some(5.0));
    assert_eq!(parser::duration("2013"), None);
    assert_eq!(parser::duration("20M plays"), None);
}

#[test]
fn sapisid_from_cookies() {
    let sapisid = |cookies: &str| Credentials { cookie_header: cookies.into() }.sapisid().map(str::to_owned);
    assert_eq!(sapisid("A=1; SAPISID=abc/def; B=2").as_deref(), Some("abc/def"));
    assert_eq!(sapisid("__Secure-3PAPISID=xyz").as_deref(), Some("xyz"));
    assert_eq!(sapisid("HSID=1"), None);
}

#[test]
fn sapisid_hash_format() {
    let hash = innertube::sapisid_hash("abc", "https://music.youtube.com", 1_700_000_000);
    assert!(hash.starts_with("SAPISIDHASH 1700000000_"));
    assert_eq!(hash.len(), "SAPISIDHASH 1700000000_".len() + 40);
}

#[test]
fn client_version_dates() {
    assert_eq!(innertube::civil_date(0), (1970, 1, 1));
    assert_eq!(innertube::civil_date(20_742), (2026, 10, 16));
    let version = innertube::client_version("1", "01.00");
    assert!(version.starts_with("1.20") && version.ends_with(".01.00") && version.len() == 16);
}

#[test]
fn published_profiles_are_validated() {
    let data = std::fs::read(format!("{}/../../../clients.json", env!("CARGO_MANIFEST_DIR"))).unwrap();
    let profiles = stream::decode_profiles(&data).expect("the published clients.json decodes");
    assert!(profiles.iter().all(stream::ClientProfile::is_valid));
    let bad = br#"{"audio":[{"clientName":"bad name; rm","clientVersion":"1","clientNameId":"1","userAgent":"x"}]}"#;
    assert!(stream::decode_profiles(bad).is_none());
}

/// Hits the network. Run with `YTF_LIVE=1 cargo test` to check playback still resolves.
#[tokio::test]
async fn live_stream_resolves() {
    if std::env::var("YTF_LIVE").as_deref() != Ok("1") {
        return;
    }
    let api = MusicApi::new();
    let resolver = StreamResolver::new(None);
    let info = resolver.resolve(&api.innertube, "dQw4w9WgXcQ").await.expect("resolves");
    assert!(info.content_length > 1_000_000);
    assert!((info.duration.unwrap_or(0.0) - 213.0).abs() < 2.0);
    let results = api.search("daft punk", None).await.expect("searches");
    assert!(!results.items.is_empty());
}
