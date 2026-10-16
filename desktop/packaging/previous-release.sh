#!/usr/bin/env bash
# Puts the newest published desktop release older than VERSION into OUTPUT_DIR (its release feed
# and its full package for CHANNEL), so `vpk pack` builds a delta update from it:
#
#   desktop/packaging/previous-release.sh CHANNEL VERSION OUTPUT_DIR
#
# CHANNEL is Velopack's channel (win or linux). Without a previous release it does nothing, and
# the release has only a full package. Uses the GitHub API (GH_TOKEN, if set, avoids rate limits).
# `vpk download github` isn't used: it reads only the 10 newest releases, and this repository's
# Mac releases (v*) would push the desktop ones (desktop-v*) out of that window.
set -euo pipefail
source "$(dirname "$0")/common.sh"

channel=${1:?channel (win or linux)}
version=${2:?version being released}
out=${3:?output directory}
mkdir -p "$out"

api() {
  local -a auth=()
  [[ -n "${GH_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GH_TOKEN")
  curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" ${auth[@]+"${auth[@]}"} "$@"
}

# Published (not draft) desktop releases: "<version> <feed url>" for those with this channel's feed.
candidates=$(
  for page in 1 2 3 4 5; do
    json=$(api "https://api.github.com/repos/$REPOSITORY/releases?per_page=100&page=$page")
    jq -r --arg prefix "$TAG_PREFIX" --arg feed "releases.$channel.json" '
      .[] | select(.draft | not) | select(.tag_name | startswith($prefix))
      | (.assets[] | select(.name == $feed) | .browser_download_url) as $url
      | "\(.tag_name | ltrimstr($prefix)) \($url)"' <<< "$json"
    [[ $(jq length <<< "$json") -lt 100 ]] && break
  done
)

# The newest one older than this version. A stable version builds its delta from the previous
# stable one, which is what stable copies run; a prerelease from any. (sort -V orders 0.1.10 after
# 0.1.9, but a prerelease such as 0.2.0-beta.1 after 0.2.0, hence the filter.)
versions=$(cut -d' ' -f1 <<< "$candidates" | grep -v '^$' || true)
[[ "$version" == *-* ]] || versions=$(grep -v -- - <<< "$versions" || true)
previous=$(
  { echo "$version"; echo "$versions"; } | grep -v '^$' | sort -uV \
    | awk -v v="$version" '$0 == v { print prev; exit } { prev = $0 }'
)
if [[ -z "$previous" ]]; then
  echo "No earlier desktop release with a $channel feed: this release gets only a full package."
  exit 0
fi
feed_url=$(awk -v v="$previous" '$1 == v { print $2; exit }' <<< "$candidates")
echo "Building the delta from $TAG_PREFIX$previous"

api -o "$out/releases.$channel.json" "$feed_url"
full=$(jq -r --arg v "$previous" '.Assets[] | select(.Type == "Full" and .Version == $v) | .FileName' \
  "$out/releases.$channel.json" | head -1)
[[ -n "$full" ]] || { echo "::error::$TAG_PREFIX$previous's releases.$channel.json lists no full package" >&2; exit 1; }
api -o "$out/$full" "${feed_url%/*}/$full"

# vpk trusts what it finds in the folder: check the package against the feed.
expected=$(jq -r --arg f "$full" '.Assets[] | select(.FileName == $f) | .SHA256' "$out/releases.$channel.json")
actual=$(sha256sum "$out/$full" | cut -d' ' -f1)
if [[ "$(tr '[:upper:]' '[:lower:]' <<< "$expected")" != "$actual" ]]; then
  echo "::error::$full doesn't match the SHA-256 in its release feed" >&2
  exit 1
fi
# vpk rebuilds the feed from the packages in the folder; the old feed isn't needed any more.
rm "$out/releases.$channel.json"
echo "Downloaded $full"
