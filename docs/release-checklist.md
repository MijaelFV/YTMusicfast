# Release checklist

Run through this with the release build before publishing (about 30 minutes).

## Install and update
- [ ] Fresh install from the DMG: drag to Applications, "Open Anyway" once, app opens.
- [ ] Settings → Updates → Check Now shows the right state (up to date, or the new version).
- [ ] Updating from the previous release through Sparkle installs, relaunches, and doesn't ask
      to "Open Anyway" again. Settings, sign-in, downloads and stats are still there.

## Playback
- [ ] A song starts in about a second; next/previous, seek, ±10 s, volume and mute work.
- [ ] Crossfade on and off; gapless between album tracks.
- [ ] Radio: start one from a song; the tuning chips (Popular, Discover…) change what's next.
- [ ] Shuffle, Smart Shuffle and repeat; ⌘S turns Smart Shuffle fully off.
- [ ] Video mode shows a music video; skipping non-music parts works when turned on.
- [ ] Sleep timer: 5 minutes fades out and stops; "End of song" stops after the song.
- [ ] Media keys, Control Center and the Dock menu control playback.
- [ ] Global shortcuts: record one, then use it with another app in front.

## Browse and search
- [ ] Home, Explore, Charts, moods; artist, album and playlist pages load.
- [ ] Typing in search shows completions and instant results (artist, songs); Return plays a song.
- [ ] ↑/↓ move through a song list, ⇧ extends, Return plays.

## Account (signed in)
- [ ] Sign in, Liked Music, library, history; like/dislike; add to and edit a playlist.
- [ ] Save an album to the library; subscribe to an artist; Undo on a removal.

## Your stuff
- [ ] Download a playlist; Offline Mode plays it with Wi‑Fi off.
- [ ] Local Files: add a folder, play from it.
- [ ] Your Stats shows plays after listening; "On repeat" appears on Home.
- [ ] Snooze a song: it's skipped; Undo brings it back.

## Window and system
- [ ] Double-click the top bar fills/restores the window; drag moves it.
- [ ] Full screen (green button): top bar lays out correctly, nothing slides over it.
- [ ] Narrow window: player bar and queue tabs don't overlap.
- [ ] Miniplayer and menu-bar player work.
- [ ] Shortcuts app lists YT Musicfast's actions; "Play music in YT Musicfast" plays something.
- [ ] Spanish: set the app's language to Español in System Settings → General → Language &
      Region → Applications; menus, settings and toasts are in Spanish.
- [ ] VoiceOver reads the player bar and song rows sensibly.

## Shortcuts, menus and appearance
- [ ] Restart with Wi‑Fi off: Home and Your Library show last time's content.
- [ ] One-key shortcuts (M, B, S, R, Q, L, F, /, ?) work, and don't fire while typing.
- [ ] ⌘A / ⌘C in a song list copies links; ⌘V into your playlist adds them; ⌘X moves them.
- [ ] ⌘V with a music.youtube.com link (outside a playlist) plays or opens it; `open "ytmusicfast://watch?v=…"` too.
- [ ] Pause, play and skip fade without clicks; balance and mono in Settings.
- [ ] Clicking an empty part of the player bar opens and closes the player page (cover or video in
      the middle column); buttons, links and the scrubber still do their own thing.
- [ ] Visualizer: Spectrum and Waveform follow the music (⌥-click the bar switches); Off uses no CPU.
- [ ] Notch island (notched Mac): shows with the app in the background, hover controls work.
- [ ] Settings → Command-line tool → Install; `ytmusicfast now-playing`, `play-search daft punk`.
- [ ] Light and Follow System appearances; full-screen player and lyrics stay dark.
- [ ] Go to Song Radio: page lists songs, New mix changes them, Save as Playlist works.

## Audio, video and search
- [ ] A song plays to the end with sound throughout (no silence after the middle); seeking anywhere works.
- [ ] Premium account: `ytmusicfast diagnose <song>` shows "Premium audio … ✓"; songs play in Opus 256k.
- [ ] Wi‑Fi off mid-song: it pauses with a message and resumes when back; headphones disconnecting pauses.
- [ ] A 1-hour mix starts quickly and seeks to the middle.
- [ ] Song → Video: the picture shows within about 2 s, in step with the music; the Now Playing sidebar keeps the
      song's cover and details. ⚙︎ Video quality: Auto shows what it plays, fixed sizes work.
- [ ] Queue: clicking a later song keeps the earlier ones under "Played"; radio from the playing song doesn't restart it.
- [ ] Search: typing only suggests, Return shows results; clicking outside closes the dropdown; ⌘1–⌘9 switch chips;
      the content filter menu hides AI/explicit songs at once; Back from an artist shows the results instantly.
- [ ] `clients.json` in the repository matches the built-in client (the test suite checks this).
- [ ] Press next ten times quickly: the song you stop on starts within a couple of seconds.
- [ ] Video mode on, let a song end: the next one plays as its video; Song mode: a music video in the queue plays
      as its song (or stays a video when there's none).

## Full-screen player
- [ ] ⇧⌘F opens the player over the whole screen (menu bar and Dock hidden) and Esc closes it; pressing F
      rapidly never leaves it stuck.
- [ ] The green button's full screen still works: after leaving it, the window buttons line up with the back /
      forward arrows and the corners stay rounded.
- [ ] Song mode and video mode both show the top bar and controls; they fade after a few seconds of playing and
      come back with the pointer or any key; P pins them.
- [ ] Arrow keys reach every button and menu (top bar, sleep/speed, speaker, volume); Return presses or opens them.
- [ ] Controls hidden: ← → seek, ↑ ↓ volume, with on-screen feedback that doesn't flicker when pressed quickly.
- [ ] Q opens the rail without anything jumping; Related loads; a card plays on click and on Return.
- [ ] L shows lyrics beside the cover in step with the song; over a video they show as captions.
- [ ] Click the cover to pause; a two-finger swipe skips; the screen doesn't sleep while music plays.
- [ ] A music video in full screen keeps thin bars by default; ⚙︎ → Fill screen fills the screen (a 4:3 video
      keeps its bars); View → Go to Playing Album works while a video plays.

## Casting
- [ ] Connect lists the Cast devices on the network, or says "No Cast devices found" and keeps looking.
- [ ] Cast to a TV: it plays through the TV's YouTube app; play/pause, seek, next and volume respond at once; the
      progress bar matches the TV's length; the next song follows without a gap on the TV.
- [ ] Video mode while casting: the TV shows the music video full screen; the Mac shows the cover with "Playing on
      <TV>", and the lyrics button opens the lyrics here as usual.
- [ ] Turn off "Use the TV's YouTube app" in Connect: the Mac streams instead and no video starts on the Mac while
      it switches. A local file always streams from the Mac.
- [ ] ⚙︎ → Lyrics on the TV through the YouTube app: the TV switches to the Mac's stream with lyrics over the
      video; choosing it again turns them off. Settings → Casting's defaults apply to a TV not changed in Connect.
- [ ] Press next ten times quickly while casting: the TV ends on the right song.

## Account sync and privacy
- [ ] Signed in: a song played here appears in music.youtube.com/history; nothing does in a private session.
- [ ] Listen together: a second Mac asking to join gets an "Allow" prompt on the host.
- [ ] Phone remote: the PIN has 6 digits; a wrong one is refused.

## Publish
- [ ] Bump `MARKETING_VERSION` in project.yml; write `release-notes/<version>.md` (shown in the update prompt and
      on the GitHub release).
- [ ] `PUBLISH=1 scripts/release.sh` (also updates the cask in MijaelFV/homebrew-tap)
- [ ] `brew upgrade --cask ytmusicfast` installs the new version.
