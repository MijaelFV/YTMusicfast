# Privacy

YT Musicfast has no server, no account of its own, no analytics and no tracking. It talks to YouTube Music
the way its website does, plus the few services listed below.

## Your Google account

- You sign in on Google's own page inside the app; YT Musicfast never sees your password. The resulting
  youtube.com cookies stay in the app's private web storage and are only ever sent to YouTube.
  **Log out** in the account menu deletes them, along with the saved copies of pages.
- Signed in, what you play is reported to your account the way YouTube Music's own player does it: that a song
  played (History) and which parts you heard (recommendations, Recap), so your phone and the website stay in step.
  Turn it off in **Settings → General → Privacy → Add songs I play to my YouTube Music history**, or use a
  private session. Local files are never reported.

## What goes over the network

| To | What | When |
|---|---|---|
| `music.youtube.com`, `www.youtube.com` | Music data, search, comments, your library | While you use the app |
| `*.googlevideo.com` | Audio and video | While playing |
| `*.ytimg.com`, `*.ggpht.com`, `*.googleusercontent.com` | Covers and pictures | While browsing |
| `accounts.google.com` | Signing in | When you sign in |
| `upload.youtube.com` | Your song file | Only when you upload one |
| [`lrclib.net`](https://lrclib.net) | The song's title, artist, album and length | When lyrics are shown |
| `github.com`, `api.github.com` | Update check and download | At launch and once a day |
| `raw.githubusercontent.com` | This repository's [`clients.json`](../clients.json), the ways to ask YouTube for audio | Twice a day, and when playback fails |
| [`sponsor.ajay.app`](https://sponsor.ajay.app) | A 4-character hash prefix of the video id, so it never learns what you play | Only with **Skip non-music parts of music videos** on (off by default) |
| Your shared AI-artist list | A request for the list | Only if you set one in the content filter |

Only requests to YouTube and Google carry your account.

## On your Mac

| What | Where | Clear it in Settings → General |
|---|---|---|
| Your Stats (plays of 30 seconds or more; not private sessions) | `~/Library/Application Support/YTMusicfast/plays.json` | Privacy → Listening stats |
| Downloads | `~/Library/Application Support/YTMusicfast/Downloads` | Storage → Downloads |
| Songs you've played, for instant replays | `~/Library/Caches/YTMusicfast/audio` | Storage → Replay cache |
| Saved pages, for instant and offline loading | `~/Library/Caches/YTMusicfast/pages` | Storage → Saved pages |
| Pins, recents, filter marks, snoozed songs, settings | `~/Library/Preferences/dev.ytmusicfast.app.plist` | |

Lyrics translation runs on-device. `brew uninstall --zap --cask ytmusicfast` removes everything above.

## On your network

Nothing listens on your network unless you use it:

- **Google Cast**: devices are looked for only while the Connect panel is open; the song is served to the one you
  pick from an address with a random secret, only while casting. On a TV, by default, nothing is served: the
  TV's YouTube app plays the songs with the TV's own account, and the app sends it play/pause/seek/skip through
  YouTube's "link with TV" service, as a phone remote does. Turn off **Use the TV's YouTube app** (Connect panel,
  per TV) to stream from this Mac instead; files on this Mac always stream from it.
- **Phone remote** (off by default): a small web page that needs a 6-digit PIN and pauses after ten wrong tries.
- **Listen together**: sessions are encrypted, nearby Macs see your account's name (or your Mac's name when signed
  out), and you approve each person who joins.
- **Command-line tool**: talks to the app over a message port only programs running as you on this Mac can reach.

If YouTube refuses the app's own ways of getting audio and you have `yt-dlp` installed, the app runs it as a
fallback. It runs on your Mac and fetches from YouTube only.

Questions: open a [discussion](https://github.com/MijaelFV/YTMusicfast/discussions). Security issues: see
[SECURITY.md](../SECURITY.md).
