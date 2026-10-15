# Development

## Building

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open YTMusicfast.xcodeproj        # or build from the command line:
xcodebuild -project YTMusicfast.xcodeproj -scheme YTMusicfast -derivedDataPath build build
```

Tests (parsers run against captured YouTube responses; live checks are opt-in):

```bash
xcodebuild test -project YTMusicfast.xcodeproj -scheme YTMusicfast -derivedDataPath build
TEST_RUNNER_YTF_LIVE=1 xcodebuild test -project YTMusicfast.xcodeproj -scheme YTMusicfast -derivedDataPath build
```

Release DMG (optionally signed and notarized — see the script header): `scripts/release.sh`

## Architecture

```
YTMusicfast/
  App/        App lifecycle, menus, settings, command-line server, phone remote, notch player
  Core/       InnerTube client, forgiving JSON walker, parsers, Google session,
              lyrics (LRCLIB), local library (pins / recents)
  Playback/   StreamResolver → ChunkedAudioSource (AVAssetResourceLoader) → PlayerController (AVQueuePlayer);
              VideoController (music videos), WatchTime (what you listen to, reported to your account)
  UI/         SwiftUI views: the main window, the player page and the full-screen TV player (TVPlayer)
```

- **Stream resolution** (`StreamResolver.swift`) uses InnerTube's `VISIONOS` client, which currently returns
  plain audio URLs without signature ciphers or PO tokens. The client it presents comes from built-in
  defaults plus [`clients.json`](../clients.json) in this repository, which installs re-read twice a day (and at
  once when YouTube refuses every client they know): when YouTube retires a client, publishing a working one
  there fixes playback everywhere without an update — watch yt-dlp's client list.
- **Audio quality:** songs play YouTube's **Opus** stream (~160 kbps, better than its 128 kbps AAC),
  repackaged from WebM into MP4 on the fly (`WebMOpus`, packets untouched) since AVFoundation can't open
  WebM. **Premium** accounts get YouTube Music Premium's **Opus 256 kbps** (and AAC 256 kbps for Cast and
  long recordings): those addresses are only usable through YouTube Music's web player code, which
  `PremiumAudio` runs with [yt-dlp/ejs](https://github.com/yt-dlp/ejs) (bundled in `Resources/Solver`,
  Unlicense; bundles meriyah, ISC, and astring, MIT) in JavaScriptCore. Any failure falls back to the
  standard stream. `ytmusicfast diagnose <song>` reports what YouTube offers and what works.
- **Parsing** walks the response tree for known renderers instead of hard-coding paths, so layout changes
  on YouTube's side tend to degrade gracefully rather than break pages.
- YouTube's audio is **fragmented MP4** whose header also states the full length; AVFoundation adds that
  to the fragments and believed every song was twice as long — while streaming it then stopped fetching
  around the middle and played on in silence. `FragmentedMP4` zeroes those header fields as the first
  chunk arrives (and fixes cached files before they play).
- Songs (up to ~20 min) download whole into a file on disk (gapless, instant replays, no RAM cost).
  **Long recordings** (podcasts, mixes, streams) play as **HLS**, built from the file's own fragment index
  and served from `127.0.0.1` (`HLSServer`): AVFoundation reads a plain fragmented MP4 end to end before
  playing, which for a 12-hour stream meant ~700 MB downloaded and held in memory first.
