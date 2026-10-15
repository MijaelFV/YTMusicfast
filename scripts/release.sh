#!/usr/bin/env bash
# Builds a release: DMG plus the Sparkle update feed (appcast.xml) in dist/.
#
#   scripts/release.sh               # build dist/YTMusicfast-x.y.z.dmg and dist/appcast.xml
#   PUBLISH=1 scripts/release.sh     # ...and create GitHub release vX.Y.Z with both attached, and
#                                    # update the Homebrew cask in MijaelFV/homebrew-tap
#
# Bump MARKETING_VERSION in project.yml first. The app is ad-hoc signed (no Apple Developer
# account): people click "Open Anyway" once on first install; Sparkle updates after that don't ask.
# Updates are signed with the EdDSA key in the maintainer's Keychain (Sparkle account
# "ytmusicfast"); without it, existing installs can't verify — back it up with
#   build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account ytmusicfast -x key-backup
#
# Optional, if you ever get one: SIGN_IDENTITY="Developer ID Application: …" and NOTARY_PROFILE.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
APP_NAME=YTMusicfast          # project, scheme and file names
DISPLAY_NAME="YT Musicfast"   # what users see (the .app and the DMG volume)
BUILD_DIR=build/release
DIST_DIR=dist
TAP_REPO=MijaelFV/homebrew-tap   # Homebrew tap (brew tap mijaelfv/tap)
APP="$BUILD_DIR/Build/Products/Release/$DISPLAY_NAME.app"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Building $APP_NAME $VERSION"
xcodegen generate --quiet
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" -quiet clean build CODE_SIGN_IDENTITY=-

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "==> Signing with Developer ID (hardened runtime)"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "==> No SIGN_IDENTITY: ad-hoc signed. Users will need System Settings > Privacy & Security > Open Anyway the first time."
fi

echo "==> Creating DMG"
# dmgbuild lays out the window (background, size, icon positions) without scripting Finder;
# it lives in a virtualenv under build/. The background comes from scripts/make-dmg-background.swift.
DMGBUILD_ENV=build/dmgbuild-env
if [[ ! -x "$DMGBUILD_ENV/bin/dmgbuild" ]]; then
  python3 -m venv "$DMGBUILD_ENV"
  "$DMGBUILD_ENV/bin/pip" install --quiet dmgbuild==1.6.7
fi
mkdir -p "$DIST_DIR"
rm -f "$DMG"
"$DMGBUILD_ENV/bin/dmgbuild" -s scripts/dmg/settings.py -D app="$APP" -D background=scripts/dmg/background.png \
  "$DISPLAY_NAME" "$DMG" >/dev/null

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing (this takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "==> Signing the update feed"
SPARKLE_BIN="$BUILD_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"
FEED_DIR=$(mktemp -d)
cp "$DMG" "$FEED_DIR/"
[[ -f "release-notes/$VERSION.md" ]] && cp "release-notes/$VERSION.md" "$FEED_DIR/$APP_NAME-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" --account ytmusicfast --embed-release-notes \
  --download-url-prefix "https://github.com/MijaelFV/YTMusicfast/releases/download/v$VERSION/" \
  --link "https://github.com/MijaelFV/YTMusicfast" -o "$DIST_DIR/appcast.xml" "$FEED_DIR"
rm -rf "$FEED_DIR"

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "$SHA  $DMG"

echo "==> Done: $DMG and $DIST_DIR/appcast.xml"

if [[ -n "${PUBLISH:-}" ]]; then
  echo "==> Publishing GitHub release v$VERSION"
  NOTES="release-notes/$VERSION.md"
  gh release create "v$VERSION" "$DMG" "$DIST_DIR/appcast.xml" --title "YT Musicfast $VERSION" \
    $([[ -f "$NOTES" ]] && echo --notes-file "$NOTES" || echo --generate-notes)

  echo "==> Updating the Homebrew cask in $TAP_REPO"
  CASK_URL="repos/$TAP_REPO/contents/Casks/ytmusicfast.rb"
  gh api "$CASK_URL" --jq .content | base64 -d \
    | sed -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 .*/  sha256 \"$SHA\"/" > "$DIST_DIR/ytmusicfast.rb"
  gh api -X PUT "$CASK_URL" -f message="ytmusicfast $VERSION" -f content="$(base64 < "$DIST_DIR/ytmusicfast.rb")" \
    -f sha="$(gh api "$CASK_URL" --jq .sha)" >/dev/null
fi
