# YT Musicfast for Windows and Linux

The Windows and Linux app, in Rust: [Slint](https://slint.dev) for the interface and
[libmpv](https://mpv.io) for playback. It's a Cargo workspace:

```
crates/
  ytm-core/      YouTube Music: InnerTube client, parsers, streams, lyrics (a port of the Mac app's Core)
  ytm-update/    In-app updates with Velopack
  ytmusicfast/   The app (binary: ytmusicfast)
packaging/       Icons, the Windows installer, the AppImage, the Flatpak (see Packaging)
release-notes/   <version>.md: what's new, shown on the release and in the update
```

## Building and running

Rust stable (`rustup`), then libmpv and Slint's system libraries:

- **Debian, Ubuntu:**
  `sudo apt install pkg-config libmpv-dev libfontconfig-dev libxkbcommon-dev libxcb-shape0-dev libxcb-xfixes0-dev`
- **Fedora:** `sudo dnf install pkgconf-pkg-config mpv-devel fontconfig-devel libxkbcommon-devel libxcb-devel`
- **Arch:** `sudo pacman -S pkgconf mpv fontconfig libxkbcommon libxcb`
- **Windows:** Visual Studio's C++ build tools, and libmpv: download the `mpv-dev-x86_64-*.7z` named in
  [`.github/actions/libmpv-windows`](../.github/actions/libmpv-windows/action.yml), extract it, and make
  `mpv.lib` from `libmpv-2.dll` as that action does. Put the folder on `LIB` (to link) and `PATH` (to
  run).

```bash
cd desktop
cargo run -p ytmusicfast              # the app
cargo test --workspace                # tests (parsers run against the Mac app's captured responses)
YTF_LIVE=1 cargo test --workspace     # plus the checks against the live services
cargo clippy --workspace --all-targets -- -D warnings
```

## Updates

Copies installed by the Windows installer or run as the AppImage update themselves with
[Velopack](https://velopack.io) from this repository's `desktop-v*` releases, the way the Mac app
does with Sparkle: a small delta package when possible, no administrator rights, applied when the app
quits. Development builds, distribution packages and the Flatpak don't (Flatpak updates come from
Flatpak). The app wires it up with `ytm-update`:

```rust
fn main() {
    ytm_update::startup(); // first thing: the installer runs the app to finish installs and updates
    // ...
    // Later, on a background thread, once a day (ytm_update::CHECK_INTERVAL):
    if let Some(update) = ytm_update::check() {
        ytm_update::download(&update, |percent| { /* progress */ })?;
        ytm_update::apply_on_quit(&update)?; // or apply_and_restart() when the user asks for it now
    }
}
```

Releases built from an app that doesn't call `startup()` can't install, so the release workflow
refuses to publish one.

## Packaging

[`.github/workflows/desktop-release.yml`](../.github/workflows/desktop-release.yml) builds everything;
the scripts it runs also work by hand.

| File in the release | What it is |
|---|---|
| `YTMusicfast-win-Setup.exe` | Windows installer: installs for the current user in `%LocalAppData%\YTMusicfast`, adds Start menu and desktop shortcuts and an uninstaller |
| `YTMusicfast-win-Portable.zip` | The same app without installing; also updates itself |
| `YTMusicfast.AppImage` | Linux: runs as is on glibc 2.36 or later (Debian 12, Ubuntu 23.04, Fedora 37 and newer); updates itself |
| `YTMusicfast-<version>-x86_64.flatpak` | Linux: a Flatpak bundle, `flatpak install --user <file>` |
| `releases.win.json`, `releases.linux.json`, `*.nupkg` | What installed copies download to update |

**Windows** (Git Bash, after `cargo build --release -p ytmusicfast`; needs `dotnet tool install -g vpk
--version 1.2.161` and [rcedit](https://github.com/electron/rcedit)):

```bash
packaging/previous-release.sh win 0.1.0 releases     # optional: the last release, for a delta package
packaging/windows/package.sh --mpv-dir <folder with libmpv-2.dll> --rcedit rcedit-x64.exe \
  --releases releases --publish publish
```

The exe gets the icon (`packaging/icons/ytmusicfast.ico`) and version information; `libmpv-2.dll`
and the sign-in helper `ytmusicfast-signin.exe` (when it's built) ship next to it. The C runtime is
linked statically (`-C target-feature=+crt-static`), so nobody needs the Visual C++ Redistributable.

**AppImage** (on Debian 12, the oldest system it supports, e.g. `docker run -it -v "$PWD:/src"
debian:bookworm`; needs the build packages above plus `patchelf squashfs-tools` and vpk):

```bash
packaging/previous-release.sh linux 0.1.0 releases
packaging/linux/package.sh --releases releases --publish publish
```

It bundles libmpv and everything it needs except what has to come from the running system (the C
library, the GPU drivers' OpenGL, the display and sound servers' libraries, fonts:
[`packaging/linux/excludelist`](packaging/linux/excludelist)). Every binary finds the bundled
libraries through an `$ORIGIN` RUNPATH, not `LD_LIBRARY_PATH`, so programs the app opens (the
browser, the file manager) run with the system's own. The sign-in helper is the exception: its
window is WebKitGTK, which can't be bundled reliably, so it uses the system's GTK and WebKitGTK 4.1
(installed on GNOME desktops; elsewhere `libwebkit2gtk-4.1-0` or `webkit2gtk4.1`). The release
workflow loads the bundled libmpv and plays a file on Debian 12, Ubuntu 24.04, Fedora and Arch with
only their desktop libraries installed.

**Flatpak** ([`packaging/flatpak`](packaging/flatpak/io.github.mijaelfv.YTMusicfast.yml), freedesktop
26.08 runtime, libmpv built as modules without GPL-only parts; needs `flatpak-builder` and
[flatpak-cargo-generator.py](https://github.com/flatpak/flatpak-builder-tools/tree/master/cargo)):

```bash
python3 flatpak-cargo-generator.py desktop/Cargo.lock -o desktop/packaging/flatpak/cargo-sources.json
flatpak-builder --user --install-deps-from=flathub --force-clean --install build \
  desktop/packaging/flatpak/io.github.mijaelfv.YTMusicfast.yml
flatpak run io.github.mijaelfv.YTMusicfast
```

Permissions: network, sound (PulseAudio, served by PipeWire too), Wayland/X11 and the GPU, the media
controls' D-Bus name (`org.mpris.MediaPlayer2.ytmusicfast`), the Secret Service (the sign-in is kept
in the keyring) and notifications. The freedesktop runtime has no WebKitGTK, so the Flatpak is built
without the sign-in helper for now; signing in inside the Flatpak needs either the GNOME runtime
(`org.gnome.Platform`, which includes WebKitGTK 4.1) or a sign-in that doesn't need a web view.

The icons come from the Mac icon: `swift desktop/packaging/make-icons.swift` (on a Mac) regenerates
the `.ico` and the PNGs.

## Releasing

1. Bump `version` in `desktop/Cargo.toml` (`[workspace.package]`) and run `cargo check` so
   `Cargo.lock` follows.
2. Write `desktop/release-notes/<version>.md`, and add a `<release version="…" date="…">` to
   [`packaging/linux/io.github.mijaelfv.YTMusicfast.metainfo.xml`](packaging/linux/io.github.mijaelfv.YTMusicfast.metainfo.xml).
3. Optionally try it first: Actions → Desktop release → Run workflow, with a draft tag such as
   `desktop-v0.2.0-rc.1`. The packages land in a draft release only you can see; delete it after.
4. Commit, then tag and push: `git tag desktop-v0.2.0 && git push origin desktop-v0.2.0`.

The workflow checks the tag matches the version, builds and tests both systems, and publishes the
release with **"latest" left on the Mac release**: the Mac app's updater reads the latest release, and
the desktop updater looks only at `desktop-v*` tags. A version with a suffix (`0.2.0-beta.1`) is
published as a prerelease, and only copies running a prerelease update to prereleases. Each release
builds its delta from the previous desktop release, so keep their files attached.

While the repository is private, tag pushes don't run it (Windows and Linux minutes are billed for
private repositories); use Run workflow.

## Unsigned Windows builds

The installer and the app aren't code-signed: that needs a paid certificate or a signing service. For
people installing it this means:

- **SmartScreen.** Opening the downloaded `YTMusicfast-win-Setup.exe`, Windows may show "Windows
  protected your PC". Click **More info**, then **Run anyway**. The warning fades as a release is
  downloaded more (SmartScreen builds reputation per file), and each new version starts over.
- **Updates don't ask.** The app downloads its own updates, which Windows doesn't flag, so the
  warning only appears for the first install (and for a fresh download of the installer).
- **Smart App Control** (Windows 11, on some new installs) blocks unsigned apps outright, with no
  "Run anyway". The only way around it is turning it off in Windows Security → App & browser control
  → Smart App Control.
- Some antivirus programs are wary of unsigned installers; a false positive can be reported to the
  vendor.

Free signing for open-source projects exists (SignPath Foundation), but it needs an application
and approval; `vpk pack --signTemplate` can call any signing tool if that changes.

## Licenses

The app is MIT. Every package carries [`packaging/licenses`](packaging/licenses) (the
third-party notices, the GPL and LGPL texts, Velopack's MIT notice) next to the app's own license:
in `licenses\` beside the exe on Windows, in `usr/share/doc/ytmusicfast` in the AppImage, and in
`/app/share/licenses` in the Flatpak. The libmpv each package ships is free software under its own
terms:

- **Flatpak:** mpv and FFmpeg built without GPL parts, so LGPL 2.1 or later.
- **AppImage:** Debian 12's libmpv and its libraries, each with its Debian copyright file in
  `usr/share/doc`. Debian's mpv includes GPL parts.
- **Windows:** [shinchiro's mpv build](https://github.com/shinchiro/mpv-winbuild-cmake), built with
  mpv's `gpl` option and GPL libraries, so GPL 3. The package ships no license files of its own,
  hence the notices.

With a GPL libmpv the package as a whole is distributed under the GPL (the app's own code stays MIT),
which only asks that the license travels with it and the sources stay available: upstream mpv and
FFmpeg, Debian's source packages, and shinchiro's build scripts are all public.
