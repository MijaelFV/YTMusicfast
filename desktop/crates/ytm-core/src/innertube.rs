//! Talks to YouTube Music's private InnerTube API (`music.youtube.com/youtubei/v1`).

use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Map, Value};
use sha1::{Digest, Sha1};

use crate::json::J;

pub const BROWSER_USER_AGENT: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
const ORIGIN: &str = "https://music.youtube.com";

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("YouTube returned HTTP {0}")]
    Http(u16),
    #[error("{0}")]
    Unplayable(String),
    #[error("No playable audio stream")]
    NoAudio,
    #[error("Network error: {0}")]
    Network(#[from] reqwest::Error),
    #[error("Unexpected response: {0}")]
    Decode(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

/// Google session cookies captured from the sign-in web view.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Credentials {
    pub cookie_header: String,
}

impl Credentials {
    pub fn sapisid(&self) -> Option<&str> {
        let pairs: Vec<&str> = self.cookie_header.split(';').map(str::trim).collect();
        ["SAPISID", "__Secure-3PAPISID"].iter().find_map(|name| {
            let prefix = format!("{name}=");
            pairs.iter().find_map(|pair| pair.strip_prefix(prefix.as_str()))
        })
    }
}

pub struct InnerTube {
    http: reqwest::Client,
    credentials: Mutex<Option<Credentials>>,
    visitor_data: Mutex<Option<String>>,
    language: String,
    region: String,
}

impl InnerTube {
    pub fn new() -> Self {
        let (language, region) = locale();
        InnerTube {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(15))
                .gzip(true)
                .build()
                .expect("HTTP client"),
            credentials: Mutex::new(None),
            visitor_data: Mutex::new(None),
            language,
            region,
        }
    }

    pub fn http(&self) -> &reqwest::Client {
        &self.http
    }

    pub fn region(&self) -> &str {
        &self.region
    }

    pub fn is_authenticated(&self) -> bool {
        self.credentials.lock().unwrap().as_ref().is_some_and(|c| c.sapisid().is_some())
    }

    pub fn set_credentials(&self, credentials: Option<Credentials>) {
        *self.credentials.lock().unwrap() = credentials;
    }

    fn context(&self) -> Value {
        let mut client = json!({
            "clientName": "WEB_REMIX",
            "clientVersion": client_version("1", "01.00"),
            "hl": self.language,
            "gl": self.region,
        });
        if let Some(visitor) = self.visitor_data.lock().unwrap().clone() {
            client["visitorData"] = Value::String(visitor);
        }
        json!({ "client": client, "user": {} })
    }

    /// POSTs to an InnerTube endpoint such as `browse`, `search` or `next`.
    pub async fn post(&self, endpoint: &str, body: Value) -> Result<Value> {
        let mut payload = match body {
            Value::Object(map) => map,
            _ => Map::new(),
        };
        payload.insert("context".into(), self.context());

        let mut request = self
            .http
            .post(format!("{ORIGIN}/youtubei/v1/{endpoint}?prettyPrint=false"))
            .json(&payload)
            .header("User-Agent", BROWSER_USER_AGENT)
            .header("Origin", ORIGIN)
            .header("X-Origin", ORIGIN)
            .header("X-YouTube-Client-Name", "67")
            .header("X-YouTube-Client-Version", client_version("1", "01.00"));
        if let Some(visitor) = self.visitor_data.lock().unwrap().clone() {
            request = request.header("X-Goog-Visitor-Id", visitor);
        }
        for (key, value) in self.auth_headers(ORIGIN).unwrap_or_default() {
            request = request.header(key, value);
        }

        let response = request.send().await?;
        let status = response.status();
        if !status.is_success() {
            return Err(Error::Http(status.as_u16()));
        }
        let json: Value = serde_json::from_slice(&response.bytes().await?)?;
        let mut visitor = self.visitor_data.lock().unwrap();
        if visitor.is_none() {
            *visitor = J::new(&json).at(&["responseContext", "visitorData"]).string();
        }
        Ok(json)
    }

    /// Signed-in headers for a request to a YouTube origin (the hash covers the origin).
    pub fn auth_headers(&self, origin: &str) -> Option<Vec<(&'static str, String)>> {
        let credentials = self.credentials.lock().unwrap().clone()?;
        let sapisid = credentials.sapisid()?;
        Some(vec![
            ("Cookie", credentials.cookie_header.clone()),
            ("Authorization", sapisid_hash(sapisid, origin, unix_now())),
            ("X-Goog-AuthUser", "0".into()),
        ])
    }
}

impl Default for InnerTube {
    fn default() -> Self {
        Self::new()
    }
}

pub fn sapisid_hash(sapisid: &str, origin: &str, timestamp: u64) -> String {
    let digest = Sha1::digest(format!("{timestamp} {sapisid} {origin}").as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    format!("SAPISIDHASH {timestamp}_{hex}")
}

pub fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// YouTube's web clients are versioned by build date; yesterday's (UTC) is always accepted.
/// `client_version("1", "01.00")` → `1.20261015.01.00`.
pub fn client_version(major: &str, suffix: &str) -> String {
    let (y, m, d) = civil_date(unix_now().saturating_sub(86_400) / 86_400);
    format!("{major}.{y:04}{m:02}{d:02}.{suffix}")
}

/// Days since 1970-01-01 → (year, month, day), proleptic Gregorian.
pub fn civil_date(days: u64) -> (i64, u32, u32) {
    let z = days as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    (y, m, d)
}

/// The system's language and region, as InnerTube wants them ("en", "US").
fn locale() -> (String, String) {
    let tag = sys_locale::get_locale().unwrap_or_else(|| "en-US".into());
    let mut parts = tag.split(['-', '_']);
    let language = parts.next().filter(|l| !l.is_empty()).unwrap_or("en").to_lowercase();
    let region = parts
        .find(|p| p.len() == 2 && p.chars().all(|c| c.is_ascii_alphabetic()))
        .map(str::to_uppercase)
        .unwrap_or_else(|| "US".into());
    (language, region)
}
