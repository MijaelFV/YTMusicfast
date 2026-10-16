#!/usr/bin/env bash
# Builds the libmpv the AppImage ships, into PREFIX (lib/libmpv.so.2 and FFmpeg's libraries,
# licenses in share/doc):
#
#   desktop/packaging/linux/build-libmpv.sh PREFIX
#
# A distribution's libmpv is built to do everything (Debian 12's pulls in ~200 libraries: SDL,
# speech synthesis, LAPACK, Kerberos, GLib, D-Bus…), and bundling all that makes the AppImage big
# and fragile. The app needs much less: decoding and HTTPS streaming (FFmpeg with GnuTLS and
# dav1d), the OpenGL render API, and PulseAudio or ALSA for sound. Built without GPL parts, it's
# LGPL 2.1 or later. The same sources as the Flatpak manifest (packaging/flatpak): keep the two in
# step. Run on Debian 12 with the build packages the release workflow installs.
set -euo pipefail

prefix=${1:?prefix}
mkdir -p "$prefix"
prefix=$(cd "$prefix" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
jobs=$(nproc)
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"

fetch() {  # url sha256 file
  curl -fsSL --retry 3 -o "$work/$3" "$1"
  echo "$2  $work/$3" | sha256sum -c -
}

# mpv needs Meson 1.3 or later; Debian 12 has 1.0.
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install --quiet meson==1.9.2
meson="$work/venv/bin/meson"

echo "==> FFmpeg"
fetch https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz \
  8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e ffmpeg.tar.xz
tar -xf "$work/ffmpeg.tar.xz" -C "$work"
(
  cd "$work/ffmpeg-9.0.2"
  # Nothing found by accident (--disable-autodetect): only what's named here, including threads
  # (autodetected too), which multithreaded decoding needs.
  ./configure --prefix="$prefix" --libdir="$prefix/lib" \
    --enable-shared --disable-static --disable-debug --disable-doc --disable-programs \
    --disable-encoders --disable-muxers --disable-devices --disable-avdevice \
    --disable-autodetect --enable-pthreads --enable-zlib --enable-gnutls --enable-libdav1d
  make -j"$jobs"
  make install
  install -D -m 644 COPYING.LGPLv2.1 LICENSE.md -t "$prefix/share/doc/ffmpeg"
)

echo "==> libplacebo (linked into libmpv)"
git clone --quiet --depth 1 --branch v7.360.1 --recurse-submodules --shallow-submodules \
  https://github.com/haasn/libplacebo.git "$work/libplacebo"
[[ "$(git -C "$work/libplacebo" rev-parse HEAD)" == cee9b076f2c63104ccfd497fa79c39a867293ec4 ]] || {
  echo "libplacebo v7.360.1 isn't the expected commit" >&2
  exit 1
}
"$meson" setup "$work/libplacebo/build" "$work/libplacebo" --prefix="$prefix" --libdir=lib \
  --buildtype=release -Ddefault_library=static -Dauto_features=disabled -Dopengl=enabled \
  -Ddemos=false -Dtests=false
"$meson" install -C "$work/libplacebo/build" --quiet
install -D -m 644 "$work/libplacebo/LICENSE" -t "$prefix/share/doc/libplacebo"

echo "==> mpv"
fetch https://github.com/mpv-player/mpv/archive/v0.41.0.tar.gz \
  ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209 mpv.tar.gz
tar -xzf "$work/mpv.tar.gz" -C "$work"
"$meson" setup "$work/mpv-0.41.0/build" "$work/mpv-0.41.0" --prefix="$prefix" --libdir=lib \
  --buildtype=release -Dauto_features=disabled -Dlibmpv=true -Dcplayer=false -Dgpl=false \
  -Dbuild-date=false -Dgl=enabled -Dplain-gl=enabled -Dpulse=enabled -Dalsa=enabled \
  -Diconv=enabled -Dzlib=enabled
"$meson" install -C "$work/mpv-0.41.0/build" --quiet --strip
install -D -m 644 "$work/mpv-0.41.0/LICENSE.LGPL" "$work/mpv-0.41.0/Copyright" -t "$prefix/share/doc/mpv"

# Only what the app loads at run time and links against.
rm -rf "$prefix/share/ffmpeg" "$prefix/lib"/*.a "$prefix/share/applications" "$prefix/share/icons" \
  "$prefix/share/zsh" "$prefix/share/bash-completion"
echo "==> libmpv in $prefix/lib:"
ls -l "$prefix/lib"
