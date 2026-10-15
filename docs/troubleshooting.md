# Troubleshooting

**Songs won't play ("YouTube may have changed something").** YouTube periodically changes how its
streams work. Check for an update (an "Update to …" button appears next to your account when one is out). As an extra safety
net, if [yt-dlp](https://github.com/yt-dlp/yt-dlp) is installed (`brew install yt-dlp`), YT Musicfast
falls back to it automatically — keep it updated with `brew upgrade yt-dlp`.

**Something specific doesn't play.** `ytmusicfast diagnose <song link or id>` reports what YouTube offers for it
and what works (format numbers and yes/no only — no addresses or cookies); add `--video` for its music video.
Include the output in an issue. (The command-line tool installs from Settings → General → Command-line tool.)

**YouTube stopped answering for everyone.** Maintainers: put a working client (yt-dlp's client list is a good source)
in [`clients.json`](../clients.json) and push — installs pick it up within hours, no update needed.

**One song is skipped.** Some tracks are region-locked, removed, or Premium/age-restricted; those are
skipped with a note in the player bar.

**Sign-in says the browser isn't secure.** Close the sheet and try again; Google occasionally
challenges embedded sign-ins.
