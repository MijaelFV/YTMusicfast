# shellcheck shell=bash disable=SC2034  # the variables are for the scripts that source this
# Shared by the packaging scripts (source it; bash).

PACKAGING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "$PACKAGING_DIR/.." && pwd)"

PACK_ID=YTMusicfast                 # Velopack package id: install folder, package and feed names
PACK_TITLE="YT Musicfast"           # what people see
PACK_AUTHORS=MijaelFV
APP_ID=io.github.mijaelfv.YTMusicfast  # freedesktop/Flatpak id (desktop file, icons, metainfo)
MAIN_EXE=ytmusicfast
SIGNIN_EXE=ytmusicfast-signin       # the sign-in helper, shipped next to the app when it exists
REPOSITORY=MijaelFV/YTMusicfast
TAG_PREFIX=desktop-v

# A path Windows programs (vpk, rcedit) understand, when running in Git Bash.
native_path() {
  if command -v cygpath > /dev/null; then cygpath -w "$1"; else echo "$1"; fi
}

# The workspace version (desktop/Cargo.toml [workspace.package]), the one Velopack and the tag use.
workspace_version() {
  sed -n '/^\[workspace\.package\]/,/^\[/s/^version *= *"\(.*\)"/\1/p' "$DESKTOP_DIR/Cargo.toml"
}

# desktop/release-notes/<version>.md, if it exists.
release_notes() {
  local notes="$DESKTOP_DIR/release-notes/$1.md"
  [[ -f "$notes" ]] && echo "$notes"
  return 0
}

# Velopack's startup hook (ytm_update::startup) must run first thing in main, or the installer
# can't finish installing or updating. Its hook arguments are compiled into the binary.
has_update_hook() {
  grep -aqF -- '--veloapp-install' "$1"
}

check_update_hook() {
  local exe=$1
  if has_update_hook "$exe"; then
    echo "Velopack startup hook found in $(basename "$exe")"
  elif [[ -n "${REQUIRE_UPDATE_HOOK:-}" ]]; then
    echo "::error::$(basename "$exe") doesn't call ytm_update::startup() at the start of main; installs and updates would hang" >&2
    exit 1
  else
    echo "::warning::$(basename "$exe") doesn't call ytm_update::startup() yet; this package must not be published" >&2
  fi
}

# Fails when one of the files contains an absolute path listed one per line in $BUILD_PATHS (home
# folders, the checkout, the Cargo and rustup homes): builds use --remap-path-prefix so none of
# them end up in what people download.
check_no_build_paths() {
  local file prefix found=0
  local -a prefixes=()
  while IFS= read -r prefix; do
    [[ -n "$prefix" && "$prefix" != "/" ]] || continue
    prefixes+=("$prefix" "${prefix//\\//}")
  done <<< "${BUILD_PATHS:?one absolute path per line}"
  for file in "$@"; do
    for prefix in "${prefixes[@]}"; do
      if grep -aqF -- "$prefix" "$file"; then
        echo "::error::$(basename "$file") contains the build path $prefix" >&2
        found=1
      fi
    done
  done
  [[ $found == 0 ]] && echo "No build paths in: $(printf '%s ' "${@##*/}")"
  return $found
}
