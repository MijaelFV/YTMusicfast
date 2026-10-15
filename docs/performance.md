# Performance

Measured on 15 October 2026 on a MacBook Pro (M4, 16 GB, macOS 26.6), with the Release build of 0.1.2, signed in
with a Premium account and listening on Bluetooth headphones. Each number was measured three times (the range is
shown). Memory is the physical footprint, the "Memory" column of Activity Monitor. CPU is the share of one core.
Network time is counted separately from the app's own time, because YouTube's speed varies a lot here.

| | YT Musicfast | YouTube Music in a Safari tab |
|---|---|---|
| Download | 8.2 MB DMG (16 MB installed) | — |
| Launch to Home on screen | 0.75–0.91 s (Home's saved copy; the fresh one follows at 2.6–2.9 s) | — |
| Memory, idle on Home | 115–120 MB, plus 9–11 MB in WebKit's helper processes | 468–474 MB for the tab's web process alone |
| CPU, idle | 0.0–0.02 % | 1.1 % |
| Memory while playing (settled) | 151–176 MB (peak 220–255 MB while a new song starts) | not measured (Safari doesn't autoplay without a click) |
| CPU while playing | 2.4–2.7 % | not measured |
| New song, play to sound | 1.5–3.3 s, median 2.0 s | — |
| Song played before, play to sound | 0.41–0.42 s | — |
| Scrolling at 120 Hz, 2000 pt/s | Home: 95 % of frames under 4 ms of work, 3 % late; a long playlist: 99 % under 3.1 ms, 0.8 % late | — |
| 4K music video | YouTube offers 2160p AV1, decoded in hardware: 3840×2160 at 17 Mbps, 2.8 % CPU and 131 MB in the app | — |

## Where the time and the CPU go

- **A new song** waits for two network steps: looking up its stream (0.3–1.6 s, the player request plus a check
  that the Premium addresses download) and downloading the whole file (1–2.5 s for 4–14 MB at 4–9 MB/s here).
  Songs play from the complete file because the Opus stream is repackaged as MP4 first (see
  [development.md](development.md)). Downloading 6 pieces at once instead of 3 was faster in one round of
  16 downloads and slower in another, so it stays at 3.
- **A song played before** starts from disk. About 0.1 s is AVFoundation preparing the file. The rest is the
  time until the player's clock passes the first 10 ms of audio, which includes the Bluetooth headphones'
  output delay.
- **CPU while playing**: Opus decoding about 0.8 %, the audio output thread (with resampling from 48 kHz to the
  headphones' 44.1 kHz) about 0.7 %, and the window's once-a-second position update about 0.9 % (Time Profiler, 30 s).
- **Launch**: about 0.7 s goes by before the app is running (system launch services and loading frameworks).
  Home's saved copy shows about 0.1 s later. A build run for the first time takes about 0.8 s longer while macOS
  checks it.

## Fixed in this round

Before and after, three runs each, alternating, on the same network:

| | Before | After |
|---|---|---|
| Memory while playing, settled (90 s after the last new song) | 169–258 MB (median 218) | 151–176 MB (median 157) |
| Peak memory while songs start | 271–368 MB (median 285) | 220–255 MB (median 231) |

- **Premium's solver gives its memory back.** Premium audio runs YouTube's player code in JavaScriptCore,
  which takes about 45 MB while a song's address is worked out. The solver was already let go after a minute,
  but macOS kept the freed pages counted against the app until the system ran short of memory. They're now
  handed back as soon as it's let go.
- **Songs play from their file on disk.** Downloaded songs reached AVFoundation through a custom resource
  loader, which keeps everything it's given in memory: about the song's size again, and again for the next
  song queued (12–15 MB of "CoreMedia HTTP cache" plus a copy of the same size). An Opus song can't start
  before its whole file is in anyway, so now it plays from the file once that's written. Start times didn't
  change (median 2.0 s before and after).

## How to measure

The app logs timing milestones (`launched`, `home shown from disk`, `play`, `resolved`, `downloaded`, `sound`):

```bash
log stream --level info --predicate 'subsystem == "dev.ytmusicfast" AND category == "Perf"'
```

Memory comes from `footprint <pid>`, CPU from the process's CPU time over 60 s (`ps -o time=`), and songs are
played from the command line with `ytmusicfast play-search …`. Scrolling uses the built-in bench:
`YTMF_BENCH=1 YTMF_BENCH_TARGET=VLLM` (see `UI/ScrollBench.swift`).
