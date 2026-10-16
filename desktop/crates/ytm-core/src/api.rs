//! High-level YouTube Music operations used by the UI.

use serde_json::{json, Value};

use crate::innertube::{InnerTube, Result};
use crate::models::*;
use crate::parser;

pub struct MusicApi {
    pub innertube: InnerTube,
}

impl MusicApi {
    pub fn new() -> Self {
        MusicApi { innertube: InnerTube::new() }
    }

    /// Home, optionally narrowed by one of its mood chips.
    pub async fn home(&self, params: Option<&str>) -> Result<BrowsePage> {
        let mut body = json!({ "browseId": "FEmusic_home" });
        if let Some(params) = params {
            body["params"] = params.into();
        }
        Ok(parser::page(&self.innertube.post("browse", body).await?))
    }

    /// Autocomplete for the search field.
    pub async fn search_suggestions(&self, input: &str) -> Result<SearchSuggestions> {
        let json = self.innertube.post("music/get_search_suggestions", json!({ "input": input })).await?;
        Ok(parser::suggestions(&json))
    }

    pub async fn search(&self, query: &str, params: Option<&str>) -> Result<SearchResults> {
        let mut body = json!({ "query": query });
        if let Some(params) = params {
            body["params"] = params.into();
        }
        Ok(parser::search(&self.innertube.post("search", body).await?))
    }

    pub async fn search_continuation(&self, token: &str) -> Result<SearchResults> {
        Ok(parser::search(&self.innertube.post("search", json!({ "continuation": token })).await?))
    }

    pub async fn browse(&self, target: &BrowseTarget) -> Result<BrowsePage> {
        let mut body = json!({ "browseId": target.browse_id });
        if let Some(params) = &target.params {
            body["params"] = params.as_str().into();
        }
        let mut page = parser::page(&self.innertube.post("browse", body).await?);
        // Podcast show pages are empty in regions without YouTube Music podcasts; every show is
        // backed by a playlist of its episodes, which loads everywhere.
        if target.kind == PageKind::Podcast
            && target.browse_id.starts_with("MPSP")
            && (page.main_shelf().is_none() || page.header.is_none())
        {
            let id = format!("VL{}", &target.browse_id[4..]);
            page = parser::page(&self.innertube.post("browse", json!({ "browseId": id })).await?);
            page.chips.clear();
        }
        page.kind = target.kind;
        page.fill_track_context(target);
        Ok(page)
    }

    /// Loads the next batch for a feed or list (`continuation` token from a page or shelf).
    pub async fn continuation(&self, token: &str) -> Result<BrowsePage> {
        Ok(parser::page(&self.innertube.post("browse", json!({ "continuation": token })).await?))
    }

    /// The "radio" / up-next queue for a song, or the contents of a playlist when `playlist_id`
    /// is given. `params` picks a variant of a playlist ("wAEB": a mix built from it).
    pub async fn radio(&self, video_id: Option<&str>, playlist_id: Option<&str>, params: Option<&str>) -> Result<RadioResult> {
        let mut body = json!({
            "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        });
        if let Some(video_id) = video_id {
            body["videoId"] = video_id.into();
            body["playlistId"] = playlist_id.map(str::to_owned).unwrap_or_else(|| format!("RDAMVM{video_id}")).into();
            body["params"] = params.unwrap_or("wAEB").into();
        } else if let Some(playlist_id) = playlist_id {
            body["playlistId"] = playlist_id.into();
            if let Some(params) = params {
                body["params"] = params.into();
            }
        }
        Ok(parser::radio(&self.innertube.post("next", body).await?))
    }

    pub async fn radio_continuation(&self, token: &str) -> Result<RadioResult> {
        let body = json!({ "continuation": token, "isAudioOnly": true, "enablePersistentPlaylistPanel": true });
        Ok(parser::radio(&self.innertube.post("next", body).await?))
    }

    pub async fn raw(&self, endpoint: &str, body: Value) -> Result<Value> {
        self.innertube.post(endpoint, body).await
    }
}

impl Default for MusicApi {
    fn default() -> Self {
        Self::new()
    }
}
