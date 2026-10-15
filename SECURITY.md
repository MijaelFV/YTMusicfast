# Security

YT Musicfast handles your Google session cookies (kept in the app's private web-view store) and talks
to YouTube's private API, so security reports are very welcome.

**Please report vulnerabilities privately** through GitHub's
[private vulnerability reporting](https://github.com/MijaelFV/YTMusicfast/security/advisories/new),
not as public issues. Include what's affected, how to reproduce it and the version you tested.
You'll get a reply within a week.

Only the latest release is supported with fixes.

Especially welcome: anything that could expose the Google session, and the parts that listen on your
network while turned on — the phone remote, Listen together and the Cast media server.

## What the app does with your data

See [Privacy in the README](README.md#privacy). In short: no analytics or tracking, no servers of
its own, and sign-in happens on Google's own page — the app never sees your password.
