# UX audit

A screen-by-screen pass over YT Musicfast (0.1.2) against what a polished desktop music app is expected to
do: instant feedback on every click, keyboard navigation, context menus, drag and drop, undo, clear empty /
loading / offline / error states, and consistent spacing and type. Gaps are ranked by severity:

- **High** — something feels broken or loses the user's place or work, on a common path.
- **Medium** — a convention people expect from a desktop app is missing or inconsistent.
- **Low** — polish; worth doing when the area is touched next.

High and medium items are fixed in the same change as this document (marked ✅).

## What already meets the bar

Most of the app was already there, so this list is short on purpose:

- **Track lists**: click, ⌘-click, ⇧-click and ⇧-arrow selection; Return plays; Delete removes from your
  playlist; ⌘A / ⌘C / ⌘X / ⌘V; double-click plays; hover ▶ on the number; right-click and ⋯ menus that act on
  the whole selection; drag to a playlist in Your Library, within your playlist, or out to other apps as links.
- **Undo** on the easy-to-regret song actions: remove from playlist (back in the same place), remove from
  queue, clear queue, hide song / artist, snooze, mark as AI, remove download, remove like.
- **Loading**: skeletons laid out like the content they replace (no layout jump), cached pages shown at once,
  a top-bar spinner only for work that takes more than a moment.
- **Search**: suggestions and instant results as you type, recent searches when empty, keyboard through the
  dropdown, filter chips on ⌘1–⌘9 / ⌃Tab, offline results from this Mac that switch to YouTube's when the
  connection returns.
- **Player**: hover time bubble on the scrubber, remaining-time toggle, spinner in the play button while
  buffering, narrow windows drop the least-used buttons instead of overlapping.
- **Full-screen player**: remote-style keyboard focus, Esc closes.
- **Accessibility**: labels, values and adjustable actions on the controls; Reduce Motion respected.

## High

| # | Screen | Gap | Why it matters | Fix |
|---|---|---|---|---|
| H1 | Every page (Back / Forward) | Going back always lands at the top of the page: an album you'd scrolled half-way through, a long Home feed, search results. | Back/Forward restoring where you were is the browser-set expectation every navigable app is held to; losing your place on each Back makes browsing a list of results tiring. [1] | ✅ The main page's scroll offset is saved when you leave it and restored on Back / Forward (new navigation still starts at the top). Read from AppKit once per navigation: no per-frame cost. |
| H2 | Home, artist / album / playlist pages, Explore, Charts, Radio | A failed load showed the raw system error ("The Internet connection appears to be offline.", "YouTube returned HTTP 500") under "Couldn't load", with a Wi-Fi icon even when the network was fine, and stayed failed after the connection came back. | Offline states should say the connection is the problem (not the app), say what still works, and retry on their own when the connection returns, with a manual retry kept. [2][3] | ✅ One error view for every page: "You're offline" with a way to your downloads when it's the network, plain words otherwise, **Try Again**, and an automatic retry as soon as macOS reports the connection is back. |
| H3 | Sign in | The sheet stayed blank white while Google's page loaded, and stayed blank forever when it couldn't load (offline, captive portal). | Don't leave a blank screen while content loads; say what failed and offer a way forward. [4] | ✅ A spinner until Google's page has drawn; if it fails, "Couldn't reach Google" with the reason and **Try Again**. |
| H4 | Play / Add to queue / Play next on cards, Your Library rows and grid tiles | Playing an album or artist that isn't open yet waits for the page to load with no sign that the click registered; if it failed, nothing happened at all. Queueing a collection from a card the same. | Past ~1 s the app must show it's working; a click that silently does nothing reads as a broken button. [5] | ✅ The top-bar spinner shows "Starting playback" / "Adding to the queue" while it loads, and a failure says so in a toast. |
| H5 | Your Library → folder → Delete Folder | Deleted at once, no confirmation, no undo; its playlists fall out to the top level and the folder's name and order are gone. | Destructive actions should be undoable; if not, confirmed. Undo is preferred over "Are you sure?". [6] | ✅ "Deleted folder" toast with **Undo** (⌘Z), restoring the folder, its place and its contents. |

## Medium

| # | Screen | Gap | Fix |
|---|---|---|---|
| M1 | Player page, Lyrics | Esc did nothing; only the full-screen player closed with it. Esc dismissing a temporary view is a platform-wide habit. | ✅ Esc leaves the player page or lyrics (back to where you were) when nothing else uses it. |
| M2 | Remove from Your Library, Unsubscribe, Unpin, Remove from Recents | Toasts confirmed these but offered no Undo, unlike the song actions. Removing an album from your library is the library-level twin of removing a song from a playlist. [6] | ✅ Undo on all four. |
| M3 | Queue | Songs couldn't be dragged into the queue panel; drag and drop worked into playlists only. Dragging into the queue is the most common drag in a desktop player. [7] | ✅ Drop songs (one or a selection) on the queue to add them; the panel highlights while you drag over it. |
| M4 | Song lists | The arrow keys did nothing until a row was clicked, so the keyboard couldn't get into a list. [7] | ✅ ↓ on a page selects the first song of its main list; from there ↑ / ↓ / Return / ⇧ work as before. |
| M5 | Theme.swift | Type sizes were set ad hoc in each view (sizes 8–32 in ~25 combinations); section titles repeated `size: 22, weight: .bold` in 12 places. | ✅ A small type scale in `Theme.swift` (`pageTitle`, `sectionTitle`, `cardTitle`, `rowTitle`, `detail`); page, section, sheet and card titles use it. The remaining one-off sizes move over as views are touched. |
| M6 | Stats, durations | "1 hr 20 min" was built from English words and skipped the string catalog. | ✅ Uses the system's localized duration formatter. |

## Low (not fixed here)

| # | Screen | Gap |
|---|---|---|
| L1 | Edit menu | Undo lives on the toast (⌘Z while it shows); Apple expects Edit → Undo to name the last action and keep it available. A real undo stack would cover text fields too, so it needs care. [6] |
| L2 | Song rows | No keyboard way to open a song's menu (⇧F10 or the menu key in other desktop apps). [7] |
| L3 | Volume | The volume slider ignores the scroll wheel / two-finger scroll. |
| L4 | Connect | When the search for Cast devices finishes with none, nothing says so (only the spinner disappears). |
| L5 | Search | "Clear recent searches" has no undo. |
| L6 | Queue | No multi-select in the queue (remove or move several at once). |
| L7 | Player bar | A playback error replaces the artist line in accent colour with no action (e.g. Try Again / Skip). |

## Sources

1. Scroll restoration on back/forward — keeping position per history entry and starting new navigations at
   the top: [Maintaining scroll position](https://www.woodcentral.com/-/peter/236-2/),
   [Restoring scroll position in LiveView apps](https://elixirforum.com/t/how-to-restore-scroll-position-in-live-view-app/31548).
2. [Offline UX design guidelines (web.dev)](https://web.dev/articles/offline-ux-design-guidelines) — tell people
   the app's state and what they can still do.
3. Offline and error states — name the connection as the problem, keep a manual retry, retry on reconnect:
   [SaaS error state patterns](https://www.saasui.design/blog/saas-error-state-ux-patterns),
   [Offline states and user trust](https://www.dolfy.ai/blog/offline-states-mobile-apps-users-trust).
4. Apple HIG, [Loading](https://developer.apple.com/design/human-interface-guidelines/loading) and
   [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators) —
   avoid blank screens while content loads.
5. Nielsen Norman Group, [The 3 response-time limits](https://www.nngroup.com/videos/3-response-time-limits-interaction-design/)
   — 0.1 s feels instant, past 1 s show the system is working.
6. Apple HIG, [Undo and redo](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo) and
   [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) — prefer undo to confirmation
   for destructive actions.
7. Desktop player conventions (from long-running requests in music players' user forums and players' own
   shortcut references): queue songs by drag and from the keyboard, reach every list and its menu without
   the mouse.
