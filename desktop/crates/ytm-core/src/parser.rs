//! Turns raw InnerTube JSON into app models. Everything here is defensive: unknown renderers are
//! skipped instead of failing the whole page. A port of the Mac app's `Parser.swift`; keep the
//! two in step when YouTube changes its layout.

use serde_json::Value;

use crate::json::{ordered_keys, J};
use crate::models::*;

// MARK: Primitives

pub fn thumbnail(json: J) -> Option<String> {
    let list = json.first("thumbnails")?.array();
    let last = list.last()?.get("url").str()?;
    Some(if last.starts_with("//") { format!("https:{last}") } else { last.to_owned() })
}

pub fn page_type<'a>(endpoint: J<'a>) -> Option<&'a str> {
    endpoint
        .at(&["browseEndpoint", "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType"])
        .str()
}

pub fn browse_target(endpoint: J, title: &str) -> Option<BrowseTarget> {
    let id = endpoint.at(&["browseEndpoint", "browseId"]).string()?;
    Some(BrowseTarget {
        browse_id: id,
        kind: PageKind::from_page_type(page_type(endpoint)),
        title: title.to_owned(),
        params: endpoint.at(&["browseEndpoint", "params"]).string(),
    })
}

/// "4:09" → 249 seconds; "1:02:03" → 3723. Anything else (years, play counts) isn't a duration.
pub fn duration(text: &str) -> Option<f64> {
    let parts: Vec<&str> = text.split(':').collect();
    if !(2..=3).contains(&parts.len()) {
        return None;
    }
    let mut total = 0.0;
    for part in parts {
        if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
            return None;
        }
        total = total * 60.0 + part.parse::<f64>().ok()?;
    }
    Some(total)
}

const TYPE_LABELS: [&str; 10] = ["Song", "Video", "Episode", "Podcast", "Single", "EP", "Album", "Playlist", "Artist", "Profile"];
const SEPARATORS: [&str; 5] = [" • ", " & ", ", ", " · ", " and "];

#[derive(Default)]
pub struct Byline {
    pub artists: Vec<ArtistRef>,
    pub album: Option<AlbumRef>,
    pub duration: Option<f64>,
    pub plain: Vec<String>,
}

/// Splits byline runs into artists / album / duration / leftover text.
pub fn byline(runs: &[J]) -> Byline {
    let mut result = Byline::default();
    for run in runs {
        let Some(text) = run.get("text").str() else { continue };
        let endpoint = run.get("navigationEndpoint");
        let browse_id = endpoint.at(&["browseEndpoint", "browseId"]).string();
        match PageKind::from_page_type(page_type(endpoint)) {
            PageKind::Artist => result.artists.push(ArtistRef { name: text.to_owned(), browse_id }),
            PageKind::Album => result.album = Some(AlbumRef { name: text.to_owned(), browse_id }),
            _ => {
                if SEPARATORS.contains(&text) {
                    continue;
                }
                match duration(text) {
                    Some(d) => result.duration = Some(d),
                    None => result.plain.push(text.to_owned()),
                }
            }
        }
    }
    result
}

/// Plain text that plausibly names an artist (not a type label, play count or year).
pub fn plain_artist(texts: &[String]) -> Option<ArtistRef> {
    texts
        .iter()
        .find(|text| {
            !TYPE_LABELS.contains(&text.as_str())
                && !text.contains(" plays")
                && !text.contains(" views")
                && !text.contains(" likes")
                && !text.contains("monthly audience")
                && !text.contains("subscribers")
                && text.parse::<i64>().is_err()
        })
        .map(|name| ArtistRef { name: name.clone(), browse_id: None })
}

pub fn is_video(endpoint: J) -> bool {
    match endpoint.first("musicVideoType").and_then(J::str) {
        Some(kind) => kind != "MUSIC_VIDEO_TYPE_ATV",
        None => false,
    }
}

fn plays(plain: &[String]) -> Option<String> {
    plain.iter().find(|t| t.ends_with(" plays") || t.ends_with(" views")).cloned()
}

// MARK: Items

pub fn item(wrapper: J) -> Option<ShelfItem> {
    let r = wrapper.get("musicResponsiveListItemRenderer");
    if r.exists() {
        return responsive_item(r);
    }
    let r = wrapper.get("musicTwoRowItemRenderer");
    if r.exists() {
        return two_row_item(r);
    }
    let r = wrapper.get("playlistPanelVideoRenderer");
    if r.exists() {
        return panel_track(r).map(ShelfItem::Track);
    }
    let r = wrapper.get("musicNavigationButtonRenderer");
    if r.exists() {
        return category_button(r);
    }
    None
}

pub fn responsive_item(r: J) -> Option<ShelfItem> {
    let columns: Vec<J> = r
        .get("flexColumns")
        .array()
        .into_iter()
        .map(|c| c.at(&["musicResponsiveListItemFlexColumnRenderer", "text"]))
        .collect();
    let fixed: Vec<J> = r
        .get("fixedColumns")
        .array()
        .into_iter()
        .map(|c| c.at(&["musicResponsiveListItemFixedColumnRenderer", "text"]))
        .collect();
    let title_column = *columns.first()?;
    let title = title_column.text()?;
    let thumb = thumbnail(r.get("thumbnail"));

    let title_endpoint = title_column.runs().first().map(|run| run.get("navigationEndpoint")).unwrap_or_default();
    let video_id = r
        .at(&["playlistItemData", "videoId"])
        .string()
        .or_else(|| title_endpoint.at(&["watchEndpoint", "videoId"]).string());

    let other_columns = &columns[1..];
    if let Some(video_id) = video_id {
        let rest: Vec<J> = other_columns.iter().chain(fixed.iter()).flat_map(|c| c.runs()).collect();
        let info = byline(&rest);
        let mut artists = info.artists;
        if artists.is_empty() {
            if let Some(column) = other_columns.first() {
                if let Some(fallback) = plain_artist(&byline(&column.runs()).plain) {
                    artists = vec![fallback];
                }
            }
        }
        return Some(ShelfItem::Track(Track {
            video_id,
            title,
            artists,
            album: info.album,
            duration: info.duration,
            thumbnail: thumb,
            is_video: is_video(if title_endpoint.exists() { title_endpoint } else { r.get("overlay") }),
            // Songs count plays, videos count views.
            plays: plays(&info.plain),
            is_explicit: is_explicit(r),
            like_status: like_status(r),
            set_video_id: r.at(&["playlistItemData", "playlistSetVideoId"]).string(),
            history_token: history_token(r),
        }));
    }

    let target = browse_target(r.get("navigationEndpoint"), &title)?;
    let subtitle = other_columns.iter().filter_map(|c| c.text()).collect::<Vec<_>>().join(" • ");
    let all_runs: Vec<J> = other_columns.iter().flat_map(|c| c.runs()).collect();
    let named = byline(&all_runs).artists.into_iter().filter(|a| a.browse_id.is_some()).collect();
    Some(ShelfItem::Media(MediaItem {
        target,
        subtitle,
        thumbnail: thumb,
        playlist_id: r.get("overlay").first("watchPlaylistEndpoint").and_then(|e| e.get("playlistId").string()),
        color: None,
        artists: named,
    }))
}

pub fn two_row_item(r: J) -> Option<ShelfItem> {
    let title = r.get("title").text()?;
    let thumb = thumbnail(r.get("thumbnailRenderer"));
    let subtitle_runs = r.get("subtitle").runs();
    let endpoint = r.get("navigationEndpoint");

    if let Some(video_id) = endpoint.at(&["watchEndpoint", "videoId"]).string() {
        let info = byline(&subtitle_runs);
        let mut artists = info.artists;
        if artists.is_empty() {
            if let Some(fallback) = plain_artist(&info.plain) {
                artists = vec![fallback];
            }
        }
        return Some(ShelfItem::Track(Track {
            video_id,
            title,
            artists,
            album: info.album,
            duration: info.duration,
            thumbnail: thumb,
            is_video: is_video(endpoint),
            plays: plays(&info.plain),
            is_explicit: is_explicit(r),
            ..Default::default()
        }));
    }

    let target = browse_target(endpoint, &title)?;
    let named = byline(&subtitle_runs).artists.into_iter().filter(|a| a.browse_id.is_some()).collect();
    Some(ShelfItem::Media(MediaItem {
        target,
        subtitle: r.get("subtitle").text().unwrap_or_default(),
        thumbnail: thumb,
        playlist_id: r.get("thumbnailOverlay").first("watchPlaylistEndpoint").and_then(|e| e.get("playlistId").string()),
        color: None,
        artists: named,
    }))
}

/// Mood/genre buttons: a coloured tile that opens a category page.
pub fn category_button(r: J) -> Option<ShelfItem> {
    let title = r.get("buttonText").text()?;
    let target = browse_target(r.get("clickCommand"), &title)?;
    let color = r.at(&["solid", "leftStripeColor"]).double().map(|c| c as i64 as u32);
    Some(ShelfItem::Media(MediaItem {
        target,
        subtitle: String::new(),
        thumbnail: None,
        playlist_id: None,
        color,
        artists: Vec::new(),
    }))
}

pub fn panel_track(r: J) -> Option<Track> {
    let video_id = r.get("videoId").string()?;
    let title = r.get("title").text()?;
    let info = byline(&r.get("longBylineText").runs());
    let mut artists = info.artists;
    if artists.is_empty() {
        if let Some(fallback) = plain_artist(&info.plain) {
            artists = vec![fallback];
        }
    }
    Some(Track {
        video_id,
        title,
        artists,
        album: info.album,
        duration: r.get("lengthText").text().and_then(|t| duration(&t)),
        thumbnail: thumbnail(r.get("thumbnail")),
        is_video: is_video(r.get("navigationEndpoint")),
        is_explicit: is_explicit(r),
        like_status: like_status(r),
        ..Default::default()
    })
}

/// The little "E" badge YouTube puts next to explicit songs.
pub fn is_explicit(r: J) -> bool {
    r.get("badges")
        .array()
        .into_iter()
        .chain(r.get("subtitleBadges").array())
        .any(|b| b.at(&["musicInlineBadgeRenderer", "icon", "iconType"]).str() == Some("MUSIC_EXPLICIT_BADGE"))
}

/// History rows offer "Remove from history": a feedback token in the row's menu.
pub fn history_token(r: J) -> Option<String> {
    r.get("menu")
        .find_all("menuServiceItemRenderer")
        .into_iter()
        .find(|item| item.get("text").text().is_some_and(|t| t.to_lowercase().contains("history")))?
        .at(&["serviceEndpoint", "feedbackEndpoint", "feedbackToken"])
        .string()
}

/// Song rows carry a like button in their menu; its state says whether it's in Liked Music.
pub fn like_status(r: J) -> Option<LikeStatus> {
    r.get("menu").first("likeButtonRenderer")?.get("likeStatus").str().and_then(LikeStatus::parse)
}

// MARK: Pages

pub fn page(json: &Value) -> BrowsePage {
    let mut page = BrowsePage::default();
    walk(json, &mut page);
    page
}

fn list_continuation(shelf: J) -> Option<String> {
    shelf
        .get("continuations")
        .idx(0)
        .at(&["nextContinuationData", "continuation"])
        .string()
        .or_else(|| shelf.get("contents").array().last()?.first("continuationCommand")?.get("token").string())
}

fn items_of(list: J) -> Vec<ShelfItem> {
    list.array().into_iter().filter_map(item).collect()
}

fn walk(node: &Value, page: &mut BrowsePage) {
    match node {
        Value::Array(items) => {
            for value in items {
                walk(value, page);
            }
        }
        Value::Object(map) => {
            for key in ordered_keys(map) {
                let raw = &map[key];
                let value = J::new(raw);
                match key {
                    "musicCarouselShelfRenderer" => {
                        let header = value.at(&["header", "musicCarouselShelfBasicHeaderRenderer"]);
                        let title = header.get("title").text();
                        let more_button = header.at(&["moreContentButton", "buttonRenderer", "navigationEndpoint"]);
                        let more = if more_button.exists() {
                            more_button
                        } else {
                            header.get("title").get("runs").idx(0).get("navigationEndpoint")
                        };
                        let items = items_of(value.get("contents"));
                        if !items.is_empty() {
                            let is_rows = value.get("contents").idx(0).get("musicResponsiveListItemRenderer").exists();
                            let mut shelf = Shelf::new(if is_rows { ShelfStyle::Rows } else { ShelfStyle::Carousel }, items);
                            shelf.more_target = browse_target(more, title.as_deref().unwrap_or(""));
                            shelf.title = title;
                            shelf.label = header.get("strapline").text();
                            page.shelves.push(shelf);
                        }
                    }
                    "musicShelfRenderer" | "musicPlaylistShelfRenderer" | "musicShelfContinuation" | "musicPlaylistShelfContinuation" => {
                        let items = items_of(value.get("contents"));
                        if !items.is_empty() {
                            let mut shelf = Shelf::new(ShelfStyle::List, items);
                            shelf.title = value.get("title").text();
                            shelf.continuation = list_continuation(value);
                            shelf.is_playlist_contents = key.starts_with("musicPlaylistShelf");
                            page.shelves.push(shelf);
                        }
                    }
                    "appendContinuationItemsAction" => {
                        // Later batches of a long playlist: bare rows, with the next token on the last item.
                        let rows = value.get("continuationItems").array();
                        let items: Vec<ShelfItem> = rows.iter().copied().filter_map(item).collect();
                        if !items.is_empty() {
                            let mut shelf = Shelf::new(ShelfStyle::List, items);
                            shelf.continuation = rows.last().and_then(|r| r.first("continuationCommand")).and_then(|c| c.get("token").string());
                            shelf.is_playlist_contents = true;
                            page.shelves.push(shelf);
                        }
                    }
                    "gridRenderer" | "gridContinuation" => {
                        let items = items_of(value.get("items"));
                        if !items.is_empty() {
                            let is_categories = value.get("items").idx(0).get("musicNavigationButtonRenderer").exists();
                            let mut shelf = Shelf::new(if is_categories { ShelfStyle::Categories } else { ShelfStyle::Grid }, items);
                            shelf.title = value.at(&["header", "gridHeaderRenderer", "title"]).text();
                            shelf.continuation = value.get("continuations").idx(0).at(&["nextContinuationData", "continuation"]).string();
                            page.shelves.push(shelf);
                        }
                    }
                    "musicResponsiveHeaderRenderer" | "musicImmersiveHeaderRenderer" | "musicVisualHeaderRenderer" | "musicDetailHeaderRenderer" | "musicHeaderRenderer" => {
                        if page.header.is_none() {
                            page.header = header(value);
                        }
                    }
                    "chipCloudRenderer" => {
                        if page.chips.is_empty() {
                            page.chips = chips(value);
                        }
                    }
                    "musicDescriptionShelfRenderer" => {
                        if let Some(h) = page.header.as_mut() {
                            if h.description.is_none() {
                                h.description = value.get("description").text();
                            }
                        }
                    }
                    "sectionListRenderer" | "sectionListContinuation" => {
                        if page.continuation.is_none() {
                            page.continuation = value.get("continuations").idx(0).at(&["nextContinuationData", "continuation"]).string();
                        }
                        walk(raw, page);
                    }
                    "menu" | "responseContext" | "frameworkUpdates" | "microformat" | "trackingParams" | "musicCardShelfRenderer" => {}
                    _ => walk(raw, page),
                }
            }
        }
        _ => {}
    }
}

/// Home's mood chips: each reloads the page with its own params.
pub fn chips(cloud: J) -> Vec<SearchFilter> {
    cloud
        .get("chips")
        .array()
        .into_iter()
        .filter_map(|wrapper| {
            let chip = wrapper.get("chipCloudChipRenderer");
            Some(SearchFilter {
                title: chip.get("text").text()?,
                params: Some(chip.at(&["navigationEndpoint", "browseEndpoint", "params"]).string()?),
            })
        })
        .collect()
}

/// The playlist a watch endpoint (play/shuffle/radio button) starts.
fn watch_playlist_id(endpoint: J) -> Option<String> {
    endpoint
        .at(&["watchPlaylistEndpoint", "playlistId"])
        .string()
        .or_else(|| endpoint.at(&["watchEndpoint", "playlistId"]).string())
}

pub fn header(h: J) -> Option<PageHeader> {
    let title = h.get("title").text()?;
    let strapline = byline(&h.get("straplineTextOne").runs());
    let mut artists = strapline.artists;
    if artists.is_empty() {
        if let Some(fallback) = plain_artist(&strapline.plain) {
            artists = vec![fallback];
        }
    }
    let facepile = h.at(&["facepile", "avatarStackViewModel"]);
    let owner_name = facepile.at(&["text", "content"]).string();
    let owner_id = facepile.first("browseEndpoint").and_then(|e| e.get("browseId").string());
    let buttons = h.get("buttons").array();
    let library_toggle = buttons.iter().map(|b| b.get("toggleButtonRenderer")).find(|t| t.exists());
    let play_endpoint = buttons
        .iter()
        .map(|b| b.get("musicPlayButtonRenderer"))
        .find(|b| b.exists())
        .map(|b| b.get("playNavigationEndpoint"));
    let subscribe = h.at(&["subscriptionButton", "subscribeButtonRenderer"]);
    Some(PageHeader {
        title,
        subtitle: h.get("subtitle").text().or_else(|| h.get("monthlyListenerCount").text()),
        second_subtitle: h.get("secondSubtitle").text(),
        description: h.first("description").and_then(J::text).or_else(|| h.get("description").text()),
        thumbnail: thumbnail(h.get("thumbnail")).or_else(|| thumbnail(h)),
        artists,
        owner: owner_name.map(|name| ArtistRef { name, browse_id: owner_id }),
        owner_avatar: facepile.first("sources").and_then(|s| s.idx(0).get("url").string()),
        playlist_id: play_endpoint.and_then(watch_playlist_id),
        in_library: library_toggle.and_then(|t| t.get("isToggled").bool()),
        channel_id: subscribe.get("channelId").string(),
        subscribed: subscribe.get("subscribed").bool(),
        radio_playlist_id: watch_playlist_id(h.at(&["startRadioButton", "buttonRenderer", "navigationEndpoint"])),
        shuffle_playlist_id: watch_playlist_id(h.at(&["playButton", "buttonRenderer", "navigationEndpoint"])),
    })
}

// MARK: Search

pub fn search(json: &Value) -> SearchResults {
    let json = J::new(json);
    let mut results = SearchResults::default();

    if let Some(card) = json.first("musicCardShelfRenderer") {
        let title_run = card.get("title").get("runs").idx(0);
        let title = card.get("title").text().unwrap_or_default();
        let endpoint = title_run.get("navigationEndpoint");
        let thumb = thumbnail(card.get("thumbnail"));
        let subtitle_runs = card.get("subtitle").runs();
        results.top_subtitle = card.get("subtitle").text();
        if let Some(video_id) = endpoint.at(&["watchEndpoint", "videoId"]).string() {
            let info = byline(&subtitle_runs);
            results.top = Some(ShelfItem::Track(Track {
                video_id,
                title,
                artists: info.artists,
                album: info.album,
                duration: info.duration,
                thumbnail: thumb,
                is_video: is_video(endpoint),
                ..Default::default()
            }));
        } else if let Some(target) = browse_target(endpoint, &title) {
            let named = byline(&subtitle_runs).artists.into_iter().filter(|a| a.browse_id.is_some()).collect();
            results.top = Some(ShelfItem::Media(MediaItem {
                target,
                subtitle: card.get("subtitle").text().unwrap_or_default(),
                thumbnail: thumb,
                playlist_id: None,
                color: None,
                artists: named,
            }));
        }
    }

    let sections = match json.first("sectionListRenderer") {
        Some(list) if list.get("contents").exists() => list.get("contents").array(),
        _ => json.get("continuationContents").array(),
    };
    for section in sections {
        if section.first_key() == Some("musicCardShelfRenderer") {
            continue;
        }
        results
            .items
            .extend(section.find_all("musicResponsiveListItemRenderer").into_iter().filter_map(responsive_item));
    }
    if results.items.is_empty() {
        if let Some(shelf) = json.first("musicShelfContinuation") {
            results.items = items_of(shelf.get("contents"));
        }
    }

    // When the top result is an artist, YouTube omits that artist from the song rows below it.
    if let Some(ShelfItem::Media(top)) = &results.top {
        if top.target.kind == PageKind::Artist {
            let artist = ArtistRef { name: top.target.title.clone(), browse_id: Some(top.target.browse_id.clone()) };
            for item in results.items.iter_mut() {
                if let ShelfItem::Track(track) = item {
                    if track.artists.is_empty() {
                        track.artists = vec![artist.clone()];
                    }
                }
            }
        }
    }

    results.continuation = json
        .first("musicShelfRenderer")
        .and_then(list_continuation)
        .or_else(|| json.first("musicShelfContinuation").and_then(list_continuation));

    let chips: Vec<SearchFilter> = json
        .find_all("chipCloudChipRenderer")
        .into_iter()
        .filter_map(|chip| {
            Some(SearchFilter {
                title: chip.get("text").text()?,
                params: chip.at(&["navigationEndpoint", "searchEndpoint", "params"]).string(),
            })
        })
        .collect();
    if !chips.is_empty() {
        results.filters = std::iter::once(SearchFilter { title: "All".into(), params: None })
            .chain(chips.into_iter().filter(|c| c.params.is_some()))
            .collect();
    }
    results
}

// MARK: Radio / queue

pub fn suggestions(json: &Value) -> SearchSuggestions {
    let json = J::new(json);
    SearchSuggestions {
        queries: json
            .find_all("searchSuggestionRenderer")
            .into_iter()
            .filter_map(|s| s.at(&["navigationEndpoint", "searchEndpoint", "query"]).string().or_else(|| s.get("suggestion").text()))
            .collect(),
        items: json.find_all("musicResponsiveListItemRenderer").into_iter().filter_map(responsive_item).collect(),
    }
}

pub fn radio(json: &Value) -> RadioResult {
    let json = J::new(json);
    let panel = json
        .first("playlistPanelRenderer")
        .or_else(|| json.first("playlistPanelContinuation"))
        .unwrap_or_default();
    let tracks = panel
        .get("contents")
        .array()
        .into_iter()
        .filter_map(|entry| {
            let direct = entry.get("playlistPanelVideoRenderer");
            let renderer = if direct.exists() {
                direct
            } else {
                entry.at(&["playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer"])
            };
            panel_track(renderer)
        })
        .collect();
    let continuations = panel.get("continuations").idx(0);
    let continuation = continuations
        .at(&["nextRadioContinuationData", "continuation"])
        .string()
        .or_else(|| continuations.at(&["nextContinuationData", "continuation"]).string());
    // Tuning chips refill the queue (`queueUpdateCommand`); the "Save" chip is something else.
    let mut selected = None;
    let tuners: Vec<RadioTuner> = json
        .find_all("chipCloudChipRenderer")
        .into_iter()
        .filter_map(|chip| {
            let endpoint = chip.at(&["navigationEndpoint", "queueUpdateCommand", "fetchContentsCommand", "watchEndpoint"]);
            let title = chip.get("text").text()?;
            let playlist_id = endpoint.get("playlistId").string()?;
            if chip.get("isSelected").bool() == Some(true) {
                selected = Some(title.clone());
            }
            Some(RadioTuner { title, playlist_id, params: endpoint.get("params").string() })
        })
        .collect();
    let has_tuners = tuners.len() > 1;
    RadioResult {
        tracks,
        continuation,
        selected_tuner: if has_tuners { selected.or_else(|| tuners.first().map(|t| t.title.clone())) } else { None },
        tuners: if has_tuners { tuners } else { Vec::new() },
    }
}
