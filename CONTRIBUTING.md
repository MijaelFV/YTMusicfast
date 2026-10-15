# Contributing

Thanks for helping! A few notes to keep YT Musicfast fast and maintainable.

## Getting started

```bash
brew install xcodegen
xcodegen generate
open YTMusicfast.xcodeproj
```

`YTMusicfast.xcodeproj` is generated from `project.yml` — edit `project.yml`, not the project file.

## When YouTube changes something

Most breakage falls into two buckets:

1. **Pages look empty or wrong** — the response layout changed. Capture a fresh response into
   `YTMusicfastTests/Fixtures/`, run the tests to see what broke, and fix `Core/Parser.swift`.
   The parser searches for known renderers anywhere in the tree rather than at fixed paths, so
   fixes are usually small.
2. **Songs don't play** — stream resolution broke. Run the live tests
   (`TEST_RUNNER_YTF_LIVE=1 xcodebuild test …`). Compare with what
   [yt-dlp](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/youtube/_base.py)
   currently does, and update or add a resolver in `Playback/StreamResolver.swift`.
   Resolvers are chained, so a new strategy can be added without touching playback.

## Translations

The app is in English and Spanish. Strings live in `YTMusicfast/Resources/Localizable.xcstrings`
(Xcode's String Catalog): SwiftUI text literals are picked up automatically; other user-visible text
goes through `String(localized:)`, and counts through `Format.count` (plural forms per language).
To add a language, open the catalog in Xcode and add it, or export with
`xcodebuild -exportLocalizations -project YTMusicfast.xcodeproj -localizationPath out -exportLanguage xx`.

## Guidelines

- Keep it native: SwiftUI/AppKit/AVFoundation, no web views for UI or playback.
- Mind memory and launch time — they're the point of the app.
- Every icon-only control needs an accessibility label.
- Use the `Theme` colours rather than hard-coded ones: they follow the Dark (default), Light and System
  appearances. The player page, lyrics and full-screen player stay dark on purpose.
- Run the tests before opening a PR; add a fixture-based test when you fix a parser.
- Don't add analytics or send user data anywhere new. The user's YouTube session goes to youtube.com only, and
  anything listening on the network needs a secret or the user's approval (see `CastMediaServer`,
  `PhoneRemote`, `ListenTogether`).
- No features that need API keys, developer accounts or personal tokens for other services —
  YT Musicfast works with YouTube Music and the Mac alone.
- Capture fixtures signed out, and replace `visitorData` values with `"REDACTED"`.
- README screenshots: a debug build can show another name in place of yours —
  `defaults write dev.ytmusicfast.app screenshotNames -dict "Your Name" "John Doe"` before launching, and
  `defaults delete dev.ytmusicfast.app screenshotNames` after. Don't include song lyrics (they're copyrighted).

## Releasing (maintainers)

Follow [the release checklist](docs/release-checklist.md): bump `MARKETING_VERSION` in `project.yml`, write
`release-notes/<version>.md`, then `PUBLISH=1 scripts/release.sh` builds the DMG, signs the update feed and creates
the GitHub release; commit the updated `Casks/ytmusicfast.rb`. Updates are signed with the Sparkle key in the
maintainer's Keychain — keep a backup (see the script's header), or existing installs can't update.

By contributing you agree your work is released under the [MIT License](LICENSE), and to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
