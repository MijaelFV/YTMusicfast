//! In-app updates for the Windows and Linux app, with Velopack: the counterpart of the Mac app's
//! Sparkle updater. Releases are the `desktop-v*` GitHub Releases of the project (see
//! `.github/workflows/desktop-release.yml`); an update downloads only what changed (a delta) when
//! it can, installs without asking for administrator rights, and relaunches the app.
//!
//! - Call [`startup`] first thing in `main`: the installer and updater run the app with special
//!   arguments to set up shortcuts or finish an update, and it handles them (and may exit).
//! - Then, on a background thread (it blocks on the network), [`check`] once a day
//!   ([`CHECK_INTERVAL`]), [`download`] what it finds, and install it with [`apply_on_quit`] so the
//!   music never stops for an update, or [`apply_and_restart`] when the user asks for it now.
//!   [`download_and_apply`] does both steps at once.
//!
//! Everything is inert, and costs nothing, when the app wasn't installed by Velopack: a
//! development build, a distribution package, or the Flatpak (Flatpak updates come from the store).

use std::path::Path;
use std::sync::{Mutex, mpsc};
use std::time::Duration;

use serde::Deserialize;
use velopack::sources::UpdateSource;
use velopack::{HttpHeader, HttpOptions, UpdateCheck, UpdateManager, VelopackAsset, VelopackAssetFeed, download};

pub use velopack::Error;

/// The GitHub repository the releases come from.
pub const REPOSITORY: &str = "MijaelFV/YTMusicfast";
/// Desktop releases are tagged `desktop-v<version>`; the Mac app's are `v<version>`.
pub const TAG_PREFIX: &str = "desktop-v";
/// How often to look for updates, as the Mac app does.
pub const CHECK_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);

/// The release feeds of this many recent desktop releases are merged, so someone a few versions
/// behind can still update with deltas. Older ones update with the full package.
const FEED_RELEASES: usize = 5;
/// The Mac and desktop apps share the repository's releases: look this far back for desktop ones.
const MAX_PAGES: u32 = 5;
const API_TIMEOUT: Duration = Duration::from_secs(20);
/// Covers a full package on a slow connection; a stalled download fails instead of hanging.
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(60 * 60);

/// Handles the installer's and updater's hooks. Call it before anything else in `main`: during
/// install, update and uninstall it runs the hook and exits the process; when an update was
/// downloaded but not installed, it installs it and relaunches.
pub fn startup() {
    if in_flatpak() {
        return;
    }
    velopack::VelopackApp::build().run();
}

/// Whether this copy can update itself (it was installed by the Windows installer or runs as the
/// AppImage). When false, every other function here does nothing.
pub fn is_supported() -> bool {
    manager().is_some()
}

/// A newer version, found by [`check`].
#[derive(Debug, Clone)]
pub struct UpdateInfo {
    /// The version it updates to, e.g. "0.2.0".
    pub version: String,
    /// What's new, in Markdown (from `desktop/release-notes/<version>.md`); may be empty.
    pub notes_markdown: String,
    info: velopack::UpdateInfo,
}

/// Looks for a newer release. Blocks on the network: call it off the UI thread.
pub fn check() -> Option<UpdateInfo> {
    let manager = manager()?;
    match manager.check_for_updates() {
        Ok(UpdateCheck::UpdateAvailable(info)) => Some(UpdateInfo {
            version: info.TargetFullRelease.Version.clone(),
            notes_markdown: info.TargetFullRelease.NotesMarkdown.clone(),
            info: *info,
        }),
        Ok(UpdateCheck::NoUpdateAvailable | UpdateCheck::RemoteIsEmpty) => None,
        Err(error) => {
            log::warn!("update check failed: {error}");
            None
        }
    }
}

/// Downloads the update (a delta when possible), reporting progress from 0 to 100. Blocks: call
/// it off the UI thread. Once downloaded, the next launch installs it even if nothing else is
/// called.
pub fn download(update: &UpdateInfo, mut progress: impl FnMut(u8) + Send) -> Result<(), Error> {
    let manager = manager().ok_or_else(not_installed)?;
    let (sender, receiver) = mpsc::channel::<i16>();
    std::thread::scope(|scope| {
        scope.spawn(move || {
            for value in receiver {
                progress(value.clamp(0, 100) as u8);
            }
        });
        // The sender is dropped when this returns, which ends the progress thread.
        manager.download_updates(&update.info, Some(sender))
    })
}

/// Installs a downloaded update after the app quits, without relaunching it or showing anything.
/// Returns immediately; the app quits normally whenever the user quits it.
pub fn apply_on_quit(update: &UpdateInfo) -> Result<(), Error> {
    let manager = manager().ok_or_else(not_installed)?;
    manager.wait_exit_then_apply_updates(&update.info.TargetFullRelease, true, false, Vec::<String>::new())
}

/// Quits now, installs a downloaded update and relaunches the app. Save anything that matters
/// first: on success this does not return.
pub fn apply_and_restart(update: &UpdateInfo) -> Result<(), Error> {
    let manager = manager().ok_or_else(not_installed)?;
    manager.apply_updates_and_restart(&update.info.TargetFullRelease)
}

/// [`download`] followed by [`apply_and_restart`].
pub fn download_and_apply(update: &UpdateInfo) -> Result<(), Error> {
    download(update, |_| {})?;
    apply_and_restart(update)
}

fn manager() -> Option<UpdateManager> {
    if in_flatpak() {
        return None;
    }
    let prerelease = !semver::Version::parse(env!("CARGO_PKG_VERSION")).is_ok_and(|v| v.pre.is_empty());
    // Fails quickly, without touching the network, when the app isn't installed.
    UpdateManager::new(DesktopReleases::new(prerelease), None, None).ok()
}

fn not_installed() -> Error {
    Error::NotInstalled("this copy was not installed with the YT Musicfast installer or AppImage".to_owned())
}

/// Flatpak apps are updated by Flatpak itself (Flathub, GNOME Software, Discover).
fn in_flatpak() -> bool {
    cfg!(target_os = "linux") && (std::env::var_os("FLATPAK_ID").is_some() || Path::new("/.flatpak-info").exists())
}

/// Velopack's own GitHub source looks at the 10 newest releases of any kind; here the Mac
/// releases (tagged `v*`) would push the desktop ones out of that window. This source pages
/// through the releases and keeps only `desktop-v*` ones.
struct DesktopReleases {
    prerelease: bool,
    /// The releases the last feed came from, to find the download address of an asset.
    releases: Mutex<Vec<Release>>,
}

#[derive(Debug, Clone, Deserialize)]
struct Release {
    tag_name: String,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    prerelease: bool,
    #[serde(default)]
    assets: Vec<Asset>,
}

#[derive(Debug, Clone, Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
}

impl Release {
    fn version(&self) -> Option<semver::Version> {
        semver::Version::parse(self.tag_name.strip_prefix(TAG_PREFIX)?).ok()
    }

    fn asset_url(&self, name: &str) -> Option<&str> {
        self.assets.iter().find(|a| a.name.eq_ignore_ascii_case(name)).map(|a| a.browser_download_url.as_str())
    }
}

impl DesktopReleases {
    fn new(prerelease: bool) -> Self {
        Self { prerelease, releases: Mutex::new(Vec::new()) }
    }

    fn fetch_releases(&self) -> Result<Vec<Release>, Error> {
        let options = http_options("application/vnd.github+json", API_TIMEOUT);
        let mut found = Vec::new();
        for page in 1..=MAX_PAGES {
            let url = format!("https://api.github.com/repos/{REPOSITORY}/releases?per_page=100&page={page}");
            let releases: Vec<Release> = serde_json::from_str(&download::download_url_as_string(&url, Some(&options))?)?;
            let last_page = releases.len() < 100;
            found.extend(releases);
            if last_page || desktop_releases(found.clone(), self.prerelease).len() >= FEED_RELEASES {
                break;
            }
        }
        Ok(desktop_releases(found, self.prerelease))
    }
}

/// The published desktop releases, newest version first, at most [`FEED_RELEASES`].
fn desktop_releases(releases: Vec<Release>, prerelease: bool) -> Vec<Release> {
    let mut releases: Vec<(semver::Version, Release)> = releases
        .into_iter()
        .filter(|r| !r.draft && (prerelease || !r.prerelease))
        .filter_map(|r| Some((r.version()?, r)))
        .collect();
    releases.sort_by(|a, b| b.0.cmp(&a.0));
    releases.into_iter().take(FEED_RELEASES).map(|(_, r)| r).collect()
}

/// One feed from the `releases.<channel>.json` of several releases, without duplicates.
fn merge_feeds(feeds: impl IntoIterator<Item = VelopackAssetFeed>) -> VelopackAssetFeed {
    let mut merged = VelopackAssetFeed::default();
    for asset in feeds.into_iter().flat_map(|f| f.Assets) {
        if merged.find(&asset.FileName).is_none() {
            merged.Assets.push(asset);
        }
    }
    merged
}

fn http_options(accept: &str, timeout: Duration) -> HttpOptions {
    let header = |name: &str, value: &str| HttpHeader { Name: name.to_owned(), Value: value.to_owned() };
    HttpOptions {
        Headers: vec![
            header("Accept", accept),
            header("User-Agent", concat!("YTMusicfast/", env!("CARGO_PKG_VERSION"))),
        ],
        TimeoutMilliseconds: timeout.as_millis() as u64,
    }
}

impl UpdateSource for DesktopReleases {
    fn get_release_feed(
        &self,
        channel: &str,
        _app: &velopack::bundle::Manifest,
        _staged_user_id: &str,
    ) -> Result<VelopackAssetFeed, Error> {
        let releases = self.fetch_releases()?;
        let options = http_options("application/octet-stream", API_TIMEOUT);
        let feed_name = format!("releases.{channel}.json");
        let feeds = releases.iter().filter_map(|release| {
            let url = release.asset_url(&feed_name)?;
            match download::download_url_as_string(url, Some(&options)).map(|json| serde_json::from_str(&json)) {
                Ok(Ok(feed)) => Some(feed),
                Ok(Err(error)) => {
                    log::warn!("unreadable {feed_name} in {}: {error}", release.tag_name);
                    None
                }
                Err(error) => {
                    log::warn!("could not download {feed_name} from {}: {error}", release.tag_name);
                    None
                }
            }
        });
        let feed = merge_feeds(feeds.collect::<Vec<_>>());
        *self.releases.lock().unwrap_or_else(|e| e.into_inner()) = releases;
        Ok(feed)
    }

    fn download_release_entry(
        &self,
        asset: &VelopackAsset,
        local_file: &Path,
        progress_sender: Option<mpsc::Sender<i16>>,
    ) -> Result<(), Error> {
        let url = self
            .releases
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .find_map(|r| r.asset_url(&asset.FileName).map(str::to_owned))
            .ok_or_else(|| Error::Other(format!("{} is not attached to any desktop release", asset.FileName)))?;
        let options = http_options("application/octet-stream", DOWNLOAD_TIMEOUT);
        download::download_url_to_file(&url, local_file, Some(&options), |p| {
            if let Some(sender) = &progress_sender {
                let _ = sender.send(p);
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(tag: &str, draft: bool, prerelease: bool) -> serde_json::Value {
        serde_json::json!({
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": [{ "name": "releases.win.json", "browser_download_url": format!("https://example.invalid/{tag}/releases.win.json") }],
        })
    }

    fn parse(values: Vec<serde_json::Value>) -> Vec<Release> {
        serde_json::from_value(serde_json::Value::Array(values)).unwrap()
    }

    #[test]
    fn keeps_only_published_desktop_releases_newest_first() {
        let releases = parse(vec![
            release("v0.1.9", false, false),
            release("desktop-v0.2.0-beta.1", false, true),
            release("desktop-v0.1.10", false, false),
            release("desktop-v0.3.0", true, false),
            release("desktop-v0.1.2", false, false),
            release("desktop-vnext", false, false),
        ]);
        let tags = |list: Vec<Release>| list.into_iter().map(|r| r.tag_name).collect::<Vec<_>>();
        assert_eq!(tags(desktop_releases(releases.clone(), false)), ["desktop-v0.1.10", "desktop-v0.1.2"]);
        assert_eq!(
            tags(desktop_releases(releases, true)),
            ["desktop-v0.2.0-beta.1", "desktop-v0.1.10", "desktop-v0.1.2"]
        );
    }

    #[test]
    fn keeps_a_handful_of_releases() {
        let releases = parse((0..12).map(|i| release(&format!("desktop-v0.1.{i}"), false, false)).collect());
        let kept = desktop_releases(releases, false);
        assert_eq!(kept.len(), FEED_RELEASES);
        assert_eq!(kept[0].tag_name, "desktop-v0.1.11");
    }

    #[test]
    fn finds_assets_by_name_ignoring_case() {
        let release = &parse(vec![release("desktop-v0.1.0", false, false)])[0];
        assert_eq!(release.asset_url("RELEASES.win.json"), Some("https://example.invalid/desktop-v0.1.0/releases.win.json"));
        assert_eq!(release.asset_url("releases.linux.json"), None);
    }

    #[test]
    fn merges_feeds_without_duplicates() {
        // The shape vpk writes to releases.<channel>.json.
        let feed = |files: &[&str]| -> VelopackAssetFeed {
            let assets: Vec<_> = files
                .iter()
                .map(|f| serde_json::json!({ "PackageId": "YTMusicfast", "Version": "0.1.0", "Type": "Full", "FileName": f, "SHA1": "", "SHA256": "", "Size": 1 }))
                .collect();
            serde_json::from_value(serde_json::json!({ "Assets": assets })).unwrap()
        };
        let merged = merge_feeds([
            feed(&["YTMusicfast-0.1.1-full.nupkg", "YTMusicfast-0.1.1-delta.nupkg", "YTMusicfast-0.1.0-full.nupkg"]),
            feed(&["YTMusicfast-0.1.0-full.nupkg"]),
        ]);
        let names: Vec<_> = merged.Assets.iter().map(|a| a.FileName.as_str()).collect();
        assert_eq!(names, ["YTMusicfast-0.1.1-full.nupkg", "YTMusicfast-0.1.1-delta.nupkg", "YTMusicfast-0.1.0-full.nupkg"]);
    }

    /// Reads the real release list (YTF_LIVE=1 cargo test -p ytm-update).
    #[test]
    fn live_release_listing() {
        if std::env::var_os("YTF_LIVE").is_none() {
            return;
        }
        let releases = DesktopReleases::new(true).fetch_releases().expect("the GitHub API answers");
        assert!(releases.len() <= FEED_RELEASES);
        assert!(releases.iter().all(|r| r.version().is_some() && !r.draft));
    }

    #[test]
    fn not_installed_builds_are_inert() {
        // `cargo test` runs from target/, not from an installed copy.
        assert!(!is_supported());
        assert!(check().is_none());
    }
}
