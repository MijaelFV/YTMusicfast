#!/usr/bin/env bash
# Packages the Linux app as an AppImage with Velopack: YTMusicfast.AppImage (runs as is and updates
# itself), the full and delta update packages and the update feed (releases.linux.json).
#
#   desktop/packaging/linux/package.sh --libmpv PREFIX --releases DIR --publish DIR
#
#   --libmpv    where build-libmpv.sh installed libmpv
#   --releases  vpk's release folder; put the previous release in it first (previous-release.sh)
#               to get a delta package
#   --publish   receives only this release's new files, the ones to attach to the GitHub Release
#
# Run after `cargo build --release` on the oldest system the AppImage should run on: it bundles
# libmpv and everything it needs from that system, except what has to come from the running
# system (the C library, GPU drivers, display and sound servers, fonts; see excludelist). Built on
# Debian 12, the AppImage runs on distributions with glibc 2.36 or later. Needs patchelf,
# squashfs-tools, dpkg (for the bundled libraries' copyright files) and vpk.
# Set REQUIRE_UPDATE_HOOK=1 to fail when the app doesn't call ytm_update::startup().
set -euo pipefail
source "$(dirname "$0")/../common.sh"

while [[ $# -gt 0 ]]; do
  case $1 in
    --libmpv) libmpv_prefix=$2; shift 2 ;;
    --releases) releases=$2; shift 2 ;;
    --publish) publish=$2; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
: "${libmpv_prefix:?--libmpv}" "${releases:?--releases}" "${publish:?--publish}"

version=$(workspace_version)
target="$DESKTOP_DIR/target/release"
linux="$PACKAGING_DIR/linux"
icons="$PACKAGING_DIR/icons/hicolor"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
appdir="$work/$PACK_ID.AppDir"  # vpk takes a folder named *.AppDir as the finished AppDir
mkdir -p "$appdir"/usr/{bin,lib,share/applications,share/metainfo,share/doc}

echo "==> Building the AppDir for $PACK_TITLE $version"
install -m 755 "$target/$MAIN_EXE" "$appdir/usr/bin/"
check_update_hook "$appdir/usr/bin/$MAIN_EXE"
if [[ -f "$target/$SIGNIN_EXE" ]]; then
  # The sign-in window is a WebKitGTK web view. WebKitGTK can't be bundled reliably (it starts
  # helper processes from fixed system paths), so the helper uses the system's GTK and WebKitGTK
  # 4.1 and is left as built: no bundled libraries, no RUNPATH.
  install -m 755 "$target/$SIGNIN_EXE" "$appdir/usr/bin/"
else
  echo "::warning::$SIGNIN_EXE wasn't built; packaging without the sign-in helper"
fi

# libmpv and what it needs. The app links libmpv.so.2 (libmpv2-sys); it's bundled even when a
# build doesn't load it yet, so the AppImage is complete either way.
libmpv="$libmpv_prefix/lib/libmpv.so.2"
[[ -f "$libmpv" ]] || { echo "::error::no $libmpv (run build-libmpv.sh)" >&2; exit 1; }
export LD_LIBRARY_PATH="$libmpv_prefix/lib"  # for ldd: FFmpeg's libraries are next to libmpv
mapfile -t excluded < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$linux/excludelist" | grep -v '^$')
is_excluded() {
  local name
  for name in "${excluded[@]}"; do [[ "$1" == "$name" ]] && return 0; done
  return 1
}
bundled=()
bundle() {  # name, path
  [[ -e "$appdir/usr/lib/$1" ]] && return
  cp -L "$2" "$appdir/usr/lib/$1"
  chmod 644 "$appdir/usr/lib/$1"
  bundled+=("$2")
}
bundle libmpv.so.2 "$libmpv"
# Follow the dependencies of what is bundled, not of the system's libraries: those bring their own
# (GLib for HarfBuzz, libXau for libxcb…), and copies of them here would only be dead weight.
queue=("$appdir/usr/bin/$MAIN_EXE" "$libmpv")
while [[ ${#queue[@]} -gt 0 ]]; do
  file=${queue[0]}
  queue=("${queue[@]:1}")
  unset found
  declare -A found=()  # soname -> path, as the dynamic loader resolves them
  while read -r name arrow path _; do
    [[ "$arrow" == "=>" ]] && found[$name]=$path
  done < <(ldd "$file")
  for name in $(patchelf --print-needed "$file"); do
    is_excluded "$name" && continue
    [[ -e "$appdir/usr/lib/$name" ]] && continue
    path=${found[$name]:-}
    [[ "$path" == /* ]] || { echo "::error::$name, needed by $(basename "$file"), isn't installed" >&2; exit 1; }
    bundle "$name" "$path"
    queue+=("$path")
  done
done

# Each binary finds the bundled libraries next to it (RUNPATH), and each library finds its own
# dependencies there too: no LD_LIBRARY_PATH, which would leak into programs the app opens.
patchelf --set-rpath '$ORIGIN/../lib' "$appdir/usr/bin/$MAIN_EXE"
for lib in "$appdir"/usr/lib/*; do
  patchelf --set-rpath '$ORIGIN' "$lib"
done
echo "Bundled ${#bundled[@]} libraries:"
(cd "$appdir/usr/lib" && ls)

# Their licenses: libmpv's and FFmpeg's from the build, each Debian library's copyright file.
cp -R "$libmpv_prefix/share/doc/." "$appdir/usr/share/doc/"
for path in "${bundled[@]}"; do
  [[ "$path" == "$libmpv_prefix"/* ]] && continue
  package=$(dpkg -S "*/$(basename "$(readlink -f "$path")")" 2> /dev/null | head -1 | cut -d: -f1)
  [[ -n "$package" && -f "/usr/share/doc/$package/copyright" ]] || {
    echo "::error::no copyright file for $path" >&2
    exit 1
  }
  install -D -m 644 "/usr/share/doc/$package/copyright" "$appdir/usr/share/doc/$package/copyright"
done
install -D -m 644 "$DESKTOP_DIR/../LICENSE" "$PACKAGING_DIR"/licenses/* -t "$appdir/usr/share/doc/$MAIN_EXE/"

# The AppImage's own entry point, desktop entry, icon and AppStream metadata.
cat > "$appdir/AppRun" << EOF
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\$0")")"
exec "\$HERE/usr/bin/$MAIN_EXE" "\$@"
EOF
chmod 755 "$appdir/AppRun"
{ cat "$linux/$APP_ID.desktop"; echo "X-AppImage-Version=$version"; } > "$appdir/$APP_ID.desktop"
cp "$appdir/$APP_ID.desktop" "$appdir/usr/share/applications/"
cp "$linux/$APP_ID.metainfo.xml" "$appdir/usr/share/metainfo/$APP_ID.appdata.xml"
cp -R "$icons" "$appdir/usr/share/icons/"
cp "$icons/256x256/apps/$APP_ID.png" "$appdir/$APP_ID.png"
cp "$icons/256x256/apps/$APP_ID.png" "$appdir/.DirIcon"

echo "==> Packing with Velopack"
mkdir -p "$releases" "$publish"
before=$(ls -A "$releases")
notes=$(release_notes "$version")
notes_args=()
[[ -n "$notes" ]] && notes_args=(--releaseNotes "$notes")
vpk pack \
  --packId "$PACK_ID" \
  --packVersion "$version" \
  --packTitle "$PACK_TITLE" \
  --packAuthors "$PACK_AUTHORS" \
  --packDir "$appdir" \
  --mainExe "$MAIN_EXE" \
  --icon "$icons/256x256/apps/$APP_ID.png" \
  --compression gzip \
  --channel linux \
  --outputDir "$releases" \
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
