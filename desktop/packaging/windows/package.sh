#!/usr/bin/env bash
# Packages the Windows app with Velopack: YTMusicfast-win-Setup.exe (a per-user install, no
# administrator rights), YTMusicfast-win-Portable.zip, the full and delta update packages and the
# update feed (releases.win.json). Run from Git Bash after `cargo build --release`:
#
#   desktop/packaging/windows/package.sh --mpv-dir DIR --rcedit rcedit-x64.exe --releases DIR --publish DIR
#
#   --mpv-dir   folder with libmpv-2.dll (shipped next to the exe)
#   --rcedit    electron/rcedit, to give the exe its icon and version information
#   --releases  vpk's release folder; put the previous release in it first (previous-release.sh)
#               to get a delta package
#   --publish   receives only this release's new files, the ones to attach to the GitHub Release
#
# Needs vpk (dotnet tool install -g vpk --version <the velopack crate's version>). Set
# REQUIRE_UPDATE_HOOK=1 to fail when the app doesn't call ytm_update::startup().
set -euo pipefail
source "$(dirname "$0")/../common.sh"

while [[ $# -gt 0 ]]; do
  case $1 in
    --mpv-dir) mpv_dir=$2; shift 2 ;;
    --rcedit) rcedit=$2; shift 2 ;;
    --releases) releases=$2; shift 2 ;;
    --publish) publish=$2; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
: "${mpv_dir:?--mpv-dir}" "${rcedit:?--rcedit}" "${releases:?--releases}" "${publish:?--publish}"

version=$(workspace_version)
target="$DESKTOP_DIR/target/release"
icon="$PACKAGING_DIR/icons/ytmusicfast.ico"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

echo "==> Staging $PACK_TITLE $version"
cp "$target/$MAIN_EXE.exe" "$mpv_dir/libmpv-2.dll" "$stage/"
binaries=("$stage/$MAIN_EXE.exe")
if [[ -f "$target/$SIGNIN_EXE.exe" ]]; then
  cp "$target/$SIGNIN_EXE.exe" "$stage/"
  binaries+=("$stage/$SIGNIN_EXE.exe")
else
  echo "::warning::$SIGNIN_EXE.exe wasn't built; packaging without the sign-in helper"
fi
check_update_hook "$stage/$MAIN_EXE.exe"

# Explorer, the taskbar and the shortcuts Velopack creates show the exe's own icon and
# description; `vpk --icon` only covers Setup.exe and the uninstaller.
for exe in "${binaries[@]}"; do
  "$rcedit" "$(native_path "$exe")" \
    --set-icon "$(native_path "$icon")" \
    --set-file-version "$version" \
    --set-product-version "$version" \
    --set-version-string ProductName "$PACK_TITLE" \
    --set-version-string FileDescription "$PACK_TITLE" \
    --set-version-string CompanyName "$PACK_AUTHORS" \
    --set-version-string LegalCopyright "MIT License" \
    --set-version-string OriginalFilename "$(basename "$exe")"
done

echo "==> Packing with Velopack"
mkdir -p "$releases" "$publish"
before=$(ls -A "$releases")
notes=$(release_notes "$version")
notes_args=()
[[ -n "$notes" ]] && notes_args=(--releaseNotes "$(native_path "$notes")")
vpk pack \
  --packId "$PACK_ID" \
  --packVersion "$version" \
  --packTitle "$PACK_TITLE" \
  --packAuthors "$PACK_AUTHORS" \
  --packDir "$(native_path "$stage")" \
  --mainExe "$MAIN_EXE.exe" \
  --icon "$(native_path "$icon")" \
  --shortcuts "Desktop,StartMenuRoot" \
  --channel win \
  --outputDir "$(native_path "$releases")" \
  "${notes_args[@]}"

# Attach what this release added: not the previous release's package (it stays attached to that
# release), vpk's list of build outputs, or the RELEASES file for apps moving over from Squirrel.
while IFS= read -r file; do
  grep -qxF -- "$file" <<< "$before" && continue
  [[ "$file" == assets.*.json || "$file" == RELEASES* ]] && continue
  cp "$releases/$file" "$publish/"
done < <(ls -A "$releases")
echo "==> Ready to publish:"
ls -l "$publish"
