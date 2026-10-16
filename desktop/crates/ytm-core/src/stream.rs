//! Resolves a video id into a directly playable audio URL.
//!
//! The app introduces itself to YouTube with an InnerTube client that returns plain (un-ciphered)
//! addresses with no PO token or JS player needed. YouTube retires these from time to time, so
//! working profiles can also be published in the project's `clients.json`: every install picks
//! them up within hours, with no app update.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::Mutex;

use crate::innertube::{unix_now, Error, InnerTube, Result};
use crate::json::J;

#[derive(Clone, Debug)]
pub struct StreamInfo {
    pub url: String,
    pub content_length: u64,
    pub mime_type: String,
    pub itag: i64,
    /// Unix seconds.
    pub expires_at: u64,
    /// Loudness relative to YouTube's reference level, used for volume normalization.
    pub loudness_db: Option<f64>,
    /// Seconds.
    pub duration: Option<f64>,
    /// YouTube's playback-stats ping for this play (used to add the song to your history).
    pub stats_url: Option<String>,
}

impl StreamInfo {
    pub fn is_expired(&self) -> bool {
        unix_now() + 300 > self.expires_at
    }
}

/// How the app introduces itself to YouTube when asking for a stream.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientProfile {
    pub client_name: String,
    pub client_version: String,
    /// The `X-YouTube-Client-Name` number.
    pub client_name_id: String,
    pub user_agent: String,
    pub device_make: Option<String>,
    pub device_model: Option<String>,
    pub os_name: Option<String>,
    pub os_version: Option<String>,
}

impl ClientProfile {
    /// Mirrors yt-dlp's default as of 2026-08 (and the Mac app's built-in profile).
    pub fn built_in() -> Vec<ClientProfile> {
        vec![ClientProfile {
            client_name: "VISIONOS".into(),
            client_version: "1.02".into(),
            client_name_id: "101".into(),
            user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15".into(),
            device_make: Some("Apple".into()),
            device_model: Some("RealityDevice17,1".into()),
            os_name: Some("visionOS".into()),
            os_version: Some("26.5.23O471".into()),
        }]
    }

    /// Plain names and numbers only: a profile from the network can't smuggle anything in.
    pub fn is_valid(&self) -> bool {
        let name_ok = !self.client_name.is_empty()
            && self.client_name.len() < 40
            && self.client_name.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_');
        let id_ok = !self.client_name_id.is_empty()
            && self.client_name_id.len() < 6
            && self.client_name_id.chars().all(|c| c.is_ascii_digit());
        let fields = [
            Some(&self.client_version),
            Some(&self.user_agent),
            self.device_make.as_ref(),
            self.device_model.as_ref(),
            self.os_name.as_ref(),
            self.os_version.as_ref(),
        ];
        let fields_ok = fields
            .iter()
            .flatten()
            .all(|f| f.len() < 300 && f.chars().all(|c| (' '..='~').contains(&c)));
        name_ok && id_ok && !self.client_version.is_empty() && !self.user_agent.is_empty() && fields_ok
    }

    fn context(&self, visitor: &str, region: &str) -> Value {
        let mut client = json!({
            "clientName": self.client_name,
            "clientVersion": self.client_version,
            "userAgent": self.user_agent,
            "hl": "en",
            "gl": region,
            "visitorData": visitor,
        });
        for (key, value) in [
            ("deviceMake", &self.device_make),
            ("deviceModel", &self.device_model),
            ("osName", &self.os_name),
            ("osVersion", &self.os_version),
        ] {
            if let Some(value) = value {
                client[key] = value.as_str().into();
            }
        }
        client
    }
}

pub const PROFILES_ADDRESS: &str = "https://raw.githubusercontent.com/MijaelFV/YTMusicfast/main/clients.json";

#[derive(Deserialize)]
struct Published {
    audio: Vec<ClientProfile>,
}

/// Up to five valid profiles from a published `clients.json`.
pub fn decode_profiles(data: &[u8]) -> Option<Vec<ClientProfile>> {
    let published: Published = serde_json::from_slice(data).ok()?;
    let profiles: Vec<ClientProfile> = published.audio.into_iter().filter(ClientProfile::is_valid).take(5).collect();
    (!profiles.is_empty()).then_some(profiles)
}

struct ProfileState {
    published: Vec<ClientProfile>,
    last_check: Option<Instant>,
}

/// Audio formats in order of preference. mpv plays Opus in WebM natively, so the Opus stream
/// (~130–160 kbps, better than the AAC one) comes first; Data saver prefers the 48k AAC.
pub fn preferred_itags(data_saver: bool) -> &'static [i64] {
    if data_saver {
        &[139, 249, 140]
    } else {
        &[251, 140, 139]
    }
}

pub struct StreamResolver {
    profiles: Mutex<ProfileState>,
    profiles_file: Option<PathBuf>,
    visitor_data: Mutex<Option<String>>,
    cache: Mutex<HashMap<String, StreamInfo>>,
    pub data_saver: std::sync::atomic::AtomicBool,
}

impl StreamResolver {
    /// `profiles_file`: where published client profiles are kept between launches.
    pub fn new(profiles_file: Option<PathBuf>) -> Self {
        let published = profiles_file
            .as_ref()
            .and_then(|f| std::fs::read(f).ok())
            .and_then(|data| decode_profiles(&data))
            .unwrap_or_default();
        StreamResolver {
            profiles: Mutex::new(ProfileState { published, last_check: None }),
            profiles_file,
            visitor_data: Mutex::new(None),
            cache: Mutex::new(HashMap::new()),
            data_saver: Default::default(),
        }
    }

    /// Published profiles first (they're newer), then the built-in ones.
    async fn current_profiles(&self) -> Vec<ClientProfile> {
        let state = self.profiles.lock().await;
        let mut all = state.published.clone();
        all.extend(ClientProfile::built_in().into_iter().filter(|p| !state.published.contains(p)));
        all
    }

    /// Looks for newly published profiles; true if they changed. At most once every 10 minutes.
    pub async fn check_profiles(&self, it: &InnerTube) -> bool {
        {
            let mut state = self.profiles.lock().await;
            if state.last_check.is_some_and(|t| t.elapsed() < Duration::from_secs(600)) {
                return false;
            }
            state.last_check = Some(Instant::now());
        }
        let Ok(response) = it
            .http()
            .get(PROFILES_ADDRESS)
            .header("User-Agent", "YTMusicfast")
            .timeout(Duration::from_secs(10))
            .send()
            .await
        else {
            return false;
        };
        if response.status() != 200 {
            return false;
        }
        let Ok(data) = response.bytes().await else { return false };
        if data.len() > 64 * 1024 {
            return false;
        }
        let Some(fresh) = decode_profiles(&data) else { return false };
        let mut state = self.profiles.lock().await;
        if fresh == state.published {
            return false;
        }
        state.published = fresh;
        if let Some(file) = &self.profiles_file {
            if let Some(dir) = file.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let _ = std::fs::write(file, &data);
        }
        true
    }

    pub async fn invalidate(&self, video_id: &str) {
        self.cache.lock().await.remove(video_id);
    }

    /// The one-time hello every first song would otherwise wait for (the visitor id), done at
    /// launch instead.
    pub async fn warm_up(&self, it: &InnerTube) {
        if let Some(profile) = self.current_profiles().await.first() {
            let _ = self.visitor_id(it, profile).await;
        }
        self.check_profiles(it).await;
    }

    pub async fn resolve(&self, it: &InnerTube, video_id: &str) -> Result<StreamInfo> {
        if let Some(cached) = self.cache.lock().await.get(video_id) {
            if !cached.is_expired() {
                return Ok(cached.clone());
            }
        }
        match self.resolve_with_any_profile(it, video_id, false).await {
            Err(Error::Unplayable(reason)) if !reason.to_lowercase().contains("bot") => {
                // Your uploads and other private songs only play for your account. If that
                // doesn't work either, the song's own reason is the one worth showing.
                if it.is_authenticated() {
                    if let Ok(info) = self.resolve_with_any_profile(it, video_id, true).await {
                        return Ok(info);
                    }
                }
                Err(Error::Unplayable(reason))
            }
            other => other,
        }
    }

    /// Each profile in turn while YouTube refuses the client itself (not the song); when all are
    /// refused, checks once for newly published profiles and tries those.
    async fn resolve_with_any_profile(&self, it: &InnerTube, video_id: &str, signed_in: bool) -> Result<StreamInfo> {
        let mut last_error = Error::NoAudio;
        for round in 0..2 {
            for profile in self.current_profiles().await {
                match self.resolve_with(it, video_id, signed_in, &profile).await {
                    Ok(info) => return Ok(info),
                    Err(error) if is_client_problem(&error) => last_error = error,
                    Err(error) => return Err(error),
                }
            }
            if round > 0 || !self.check_profiles(it).await {
                break;
            }
        }
        Err(last_error)
    }

    async fn player_request(&self, it: &InnerTube, video_id: &str, profile: &ClientProfile, signed_in: bool) -> Result<Value> {
        let visitor = self.visitor_id(it, profile).await?;
        let body = json!({
            "context": { "client": profile.context(&visitor, it.region()) },
            "videoId": video_id,
            "contentCheckOk": true,
            "racyCheckOk": true,
        });
        let origin = "https://www.youtube.com";
        let mut request = it
            .http()
            .post("https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
            .json(&body)
            .header("User-Agent", &profile.user_agent)
            .header("X-YouTube-Client-Name", &profile.client_name_id)
            .header("X-YouTube-Client-Version", &profile.client_version)
            .header("X-Goog-Visitor-Id", &visitor)
            .header("Origin", origin);
        if signed_in {
            for (key, value) in it.auth_headers(origin).unwrap_or_default() {
                request = request.header(key, value);
            }
        }
        let response = request.send().await?;
        if !response.status().is_success() {
            return Err(Error::Http(response.status().as_u16()));
        }
        let json: Value = serde_json::from_slice(&response.bytes().await?)?;
        let status = J::new(&json).at(&["playabilityStatus", "status"]).str();
        if status != Some("OK") {
            let reason = J::new(&json).at(&["playabilityStatus", "reason"]).string();
            if reason.as_deref().is_some_and(|r| r.contains("bot")) {
                *self.visitor_data.lock().await = None;
            }
            return Err(Error::Unplayable(reason.unwrap_or_else(|| "This track can't be played".into())));
        }
        Ok(json)
    }

    async fn resolve_with(&self, it: &InnerTube, video_id: &str, signed_in: bool, profile: &ClientProfile) -> Result<StreamInfo> {
        let json = self.player_request(it, video_id, profile, signed_in).await?;
        let info = stream_info(&json, self.data_saver.load(std::sync::atomic::Ordering::Relaxed)).ok_or(Error::NoAudio)?;
        self.cache.lock().await.insert(video_id.to_owned(), info.clone());
        Ok(info)
    }

    /// Anonymous visitor id; without it most requests hit "Sign in to confirm you're not a bot".
    async fn visitor_id(&self, it: &InnerTube, profile: &ClientProfile) -> Result<String> {
        let mut visitor = self.visitor_data.lock().await;
        if let Some(id) = visitor.as_ref() {
            return Ok(id.clone());
        }
        let data = it
            .http()
            .get("https://www.youtube.com/sw.js_data")
            .header("User-Agent", &profile.user_agent)
            .send()
            .await?
            .bytes()
            .await?;
        // The response is prefixed with ")]}'\n" to defeat JSON hijacking.
        let json: Value = serde_json::from_slice(data.get(5..).unwrap_or_default())?;
        let id = J::new(&json)
            .idx(0)
            .idx(2)
            .idx(0)
            .idx(0)
            .idx(13)
            .string()
            .ok_or_else(|| Error::Unplayable("Couldn't get a visitor id".into()))?;
        *visitor = Some(id.clone());
        Ok(id)
    }
}

/// The best audio stream in a `player` response.
pub fn stream_info(json: &Value, data_saver: bool) -> Option<StreamInfo> {
    let root = J::new(json);
    let formats = root.at(&["streamingData", "adaptiveFormats"]).array();
    for &itag in preferred_itags(data_saver) {
        let Some(format) = formats.iter().find(|f| f.get("itag").int() == Some(itag)) else { continue };
        let (Some(url), Some(length)) = (format.get("url").string(), format.get("contentLength").int()) else { continue };
        if length <= 0 {
            continue;
        }
        let expires_at = query_value(&url, "expire").and_then(|v| v.parse().ok()).unwrap_or(unix_now() + 3 * 3600);
        return Some(StreamInfo {
            mime_type: format.get("mimeType").string().unwrap_or_else(|| "audio/mp4".into()),
            content_length: length as u64,
            itag,
            expires_at,
            loudness_db: root.at(&["playerConfig", "audioConfig", "loudnessDb"]).double(),
            duration: format
                .get("approxDurationMs")
                .double()
                .map(|ms| ms / 1000.0)
                .or_else(|| root.at(&["videoDetails", "lengthSeconds"]).double()),
            stats_url: root.at(&["playbackTracking", "videostatsPlaybackUrl", "baseUrl"]).string(),
            url,
        });
    }
    None
}

fn query_value(url: &str, name: &str) -> Option<String> {
    let parsed = url::Url::parse(url).ok()?;
    let value = parsed.query_pairs().find(|(k, _)| k == name).map(|(_, v)| v.into_owned());
    value
}

/// YouTube turning the client away (an HTTP error, a bot check, addresses it won't give out)
/// rather than the song being unavailable or the network being down.
pub fn is_client_problem(error: &Error) -> bool {
    match error {
        Error::Http(_) | Error::NoAudio => true,
        Error::Unplayable(reason) => reason.to_lowercase().contains("bot"),
        _ => false,
    }
}
