# Progress

Plan: Amarok 2/3 feature parity in milestones M0–M8 (see CLAUDE.md for commands).

## M0 — Setup and risk gates ✅
- XcodeGen project (`project.yml`), Makefile, CLAUDE.md.
- Codec xcframeworks embedded by listing the binary products on the app target (fallback 1).
- `--selftest-decoders`: WAV, AIFF, M4A, FLAC, Ogg Vorbis, Opus, MP3, WavPack, Musepack, TTA decode
  and their tags round-trip. APE not generated (SFBAudioEngine 0.14's APE encoder crashes); CAF has
  no tag support. MP3 files written by SFBAudioEngine's LAME encoder end with a truncated frame
  (mpg123 "Error reading the stream" in the last ~70 ms) — encoder artefact, decoders tolerate it.
- `--canary <dir>`: proves the snapshot approach captures NSTableView, SwiftUI (Text/Image/Canvas/List)
  and WKWebView.
- Package resolution needs `-packageAuthorizationProvider netrc` (the Keychain provider hangs).

## M1 — Core library ✅
- GRDB schema v1, scanner (incremental, moves keep statistics, unreachable roots kept), Amarok query
  language → SQL + in-memory, collection level queries, CoverStore (custom → embedded → folder), LRC,
  playlist model/proxy/navigators, playlist files, organize patterns, FolderWatcher, synthetic 20k DB.
- SFBAudioEngine only writes ID3 TDRC for full ISO timestamps; TagWriter writes mid-year timestamps
  for ID3 formats.
- Grouping queries use indexed folded key columns (`artistKey`, `albumArtistKey`, `genreKey`,
  `composerKey`).

## M2a — Playable slice ✅
- `LocalAudioEngine` (SFBAudioEngine) with the gapless bridge, EQ node and analyzer tap hook;
  `StreamEngine` (AVPlayer) for streams; `PlayerController` state machine, statistics recording,
  Now Playing / media keys, Dock menu.
- `make test-engine`: gapless chaining, stale "upcoming" ignored, 44.1 → 48 kHz advance, EQ and tap
  survive format changes, seeking. Silenced with the player's own output volume.
- `make snapshot` seeds the fixture library, plays silently through `PlayerController` (play, Next,
  queue honoured) and writes window / pane PNGs and `layout.json`.

## M2b — Playlist pane ✅
- One table row per item; album header drawn in the group's first row. Layouts are data
  (Default, No Grouping, No Grouping (Single Line), Verbose) in Playlist › Playlist Layouts.
- Sort breadcrumb (multi-level, Shuffle), progressive search (Previous/Next, field preferences,
  Show Only Matches, red when nothing matches), bottom bar (Clear, Save/Export, Undo, Redo, Show
  Active, Track Progression + Favor, length summary with queue tooltip).
- Drag to reorder (only in source order), drops from the collection and Finder (folders and
  playlist files expanded), Pop-Up Dropper over the Context pane, queue badges, stop-after,
  context menu, Delete / Return / middle-click, Edit › Undo falls through to playlist undo.
- The current playlist, active track, queue, stop-after and position are saved in `app_state` and
  restored at launch (playback resumes when "resume playback" is on and it was playing).
- Placeholders until their milestones: Context pane shows only Current Track (M3); tag editor,
  Organize Files, cover fetching, Edit Filter builder (M4); Playlists / Files / Internet / Podcasts
  pages and the Bookmark Manager (M5, M7).

## M2c — Window chrome ✅
- Track-label carousel (slide animation, drag past 1/5 to skip), volume dial, position markers on the
  seek slider (`bookmark` table), time labels that swap on click.
- Media Sources breadcrumb with bookmark menu and the category home page; collection Sort Options
  (presets and per-level menus) and filter presets.
- View menu pane toggles, Lock Layout (title bars when unlocked), Main / Slim Toolbar, Reset Layout,
  Full Screen; first-run collection folder prompt, Open With / Dock drops, Dock menu, window title.
- Snapshot variants: expanded collection, unlocked layout with slim toolbar, Media Sources home.
## M3 — Context view ✅
- `HTTPClient`: fixed User-Agent, per-host spacing (MusicBrainz 1 req/s), 429/503 retries with
  Retry-After, on-disk cache with per-host lifetimes, `StubURLProtocol` for tests and snapshots.
- `LRCLIBClient` (exact lookup, then search within ±2 s, synced preferred), `LyricsService`
  (user → tag → LRCLIB, user text never overwritten), `WikipediaClient` (MusicBrainz → Wikidata
  sitelink for artists/composers, search otherwise; `action=parse` HTML).
- Applet framework: scrolling column of applets with headers (settings popover, collapse),
  drag-to-resize, tab bar (click to scroll, drag to reorder), Configure Applets strip; enabled
  order, heights and collapsed state persist.
- Applets: Current Track (rating, statistics; recently added albums when stopped), Albums (current
  artist, expandable, drag/double-click to the playlist), Lyrics (synced highlight and auto-scroll,
  edit/save/clear, font size), Wikipedia (Artist/Composer/Album/Track, in-applet links with
  Back/Forward, language setting), Analyzer (block bars with fade bars; tap only while shown).
- Snapshot runs use canned lyrics / Wikipedia responses and capture the whole applet column.
## M4 — Library management ✅
- Edit Track Details: Summary (statistics, rating), Tags (multi-track editing with "Various",
  Per Track with Previous/Next, Guess Tags from Filename, MusicBrainz recording lookup), Lyrics,
  Labels. Writes go through `TrackEditor` (temp copy + swap) and `CollectionScanner.refresh`, so
  ids, statistics and date added survive; playlist items and the playing track update.
- Ratings from the collection and playlist context menus (half stars, several tracks at once);
  optional FMPS rating / play count written into files.
- Covers: Fetch Cover (Cover Art Archive via MusicBrainz releases, then iTunes, choose from
  candidates), Display / Set Custom / Unset, Cover Manager (filter, search, Fetch Missing Covers).
- Organize Files: pattern presets and tokens, options, live preview with conflict marking, moves
  update the collection and playlist, emptied folders are removed. Move to Trash and permanent
  Delete (with confirmation).
- Edit Filter dialog builds conditions (field, operator, value, negate; all/any) into filter text.
- Import Statistics from Apple Music (exported Library.xml): matched by path, then tags; play
  counts and dates only grow, ratings fill gaps unless replacing is chosen.
- Snapshot run captures the tag editor, Organize Files, Edit Filter and Cover Manager.
## M5 — Playlists ✅
- Media Sources › Playlists has three pages:
  - Saved Playlists: playlists stored in Amamac plus playlist files found in the collection
    folders. Replace, Add, Queue, Rename, Export As, Delete, Import, and Copy to Saved Playlists.
    The playlist bottom bar's Save writes here.
  - Dynamic Playlists: biases (Random, Match All/Any, Not, Partition, If/Else, Search, Album
    Play, Quiz Play) in a recursive editor, six presets, Previous/Upcoming counts, Allow
    duplicates. Dynamic mode trims played tracks, tops up the upcoming ones on every track change,
    forces Standard progression and resumes after relaunch. A banner above the playlist offers
    Repopulate and Turn Off.
  - Automated Playlist Generator: constraint tree (Match Tags, Duration, Playlist Length, Total
    Size, Prevent Duplicates, Spread Artists, Checkpoint, with strength and all/any groups) solved
    by simulated annealing. Presets can be saved; results are added or replace the playlist.
- Files browser: Back, Forward, Up, Home, Reload, a folder path menu, a filter, double-click to
  enter folders or add files, context menu and dragging into the playlist. The last folder is
  remembered.
- Edit Queue (⌃⌥U): reorder by dragging or Move Up/Down, Dequeue, Clear Queue.
- Bookmark Manager: position markers and saved views, with Go To, Rename, Copy Link and Delete.
  The Media Sources bookmark button offers "Bookmark This View" and the saved views.
- `amamac://navigate/position?track=ID&pos=SECONDS`, `amamac://navigate/collection?filter=…&levels=…`
  and `amamac://navigate/<category>?path=…` open from other apps, bookmarks and the manager.
- The four built-in playlist layouts were already in place from M2b.
- Snapshot run checks dynamic mode (5 previous, 10 upcoming), the generator and a collection link,
  and captures the Playlists pages, the Files browser, the Queue Editor and the Bookmark Manager.
## M6 — Audio extras ✅
- Equalizer (Tools › Equalizer…, ⌥⌘E): on/off, preamp and 10 bands (29 Hz–15 kHz, ±12 dB),
  Amarok's 19 preset names with Amamac's own curves, Manual that remembers hand-made settings,
  saved user presets, Flat. Applied at launch; band bypass keeps ReplayGain working when off.
- ReplayGain Off/Track/Album with pre-amp, a gain for untagged tracks and peak limiting. Changes
  apply to the playing track at once and to the queued gapless track.
- Fade out on stop and pause with an adjustable duration. Fades can be cancelled: resuming or
  starting another track during a fade restores the volume and the pending stop/pause never runs
  (this was a real bug before).
- Output device choice (System Default or any output device by UID) for both the file engine and
  streams; follows device changes and falls back to the default when a device disappears.
- Settings window (⌘,) with a Playback page: output device, resume on start, fading, ReplayGain
  and the three seek steps. Further pages arrive in M8.
- Tests: preset sanity and headroom, preset round trip, ReplayGain fallback and peak limiting, and
  an engine test for fade cancellation. Snapshots of the Equalizer and the Playback settings.
## M7 — Internet ✅
- Internet Radio (Media Sources › Internet) from radio-browser.info: a mirror is picked from the
  directory's server list, then Favorites, Top, Genres, Countries and Search. Stations show logo,
  tags, country and a codec badge; Ogg, Opus and FLAC streams (which macOS's streaming engine
  can't play) are hidden by default and shown dimmed when included. Play, Add, Replace, star as
  favourite (stored in the database), open homepage, copy the stream address. Playing a station
  reports the click to the directory, as its ranking expects.
- Podcast Directory: iTunes Search for podcasts with Subscribe buttons.
- Podcasts page: subscriptions with artwork and new-episode badges, expandable episode lists,
  an info pane with the plain-text description, Add Podcast (feed address), Update All,
  Import/Export OPML, per-channel settings (automatic updates, download policy, keep N
  downloads), Download / Delete Download / Show in Finder, Mark as Played / New, Unsubscribe
  (optionally deleting downloads). Downloads show progress in the row and in the Media Sources
  strip and go to ~/Music/Podcasts/<podcast>.
- An hourly update (configurable) checks channels with automatic updates and downloads new
  episodes where the channel asks for it.
- Feeds are parsed with FeedKit (RSS with iTunes tags, and Atom enclosures). A subscription marks
  only the newest episode new; updates add unseen episodes as new.
- Tests: mirror choice and codec flags, favourites round trip, subscribe/update/download/prune
  against a stubbed feed, the podcast directory, and OPML export/parse (including nested
  outlines). The snapshot run checks radio, the directory, a subscription and a download.
## M8 — Desktop integration and polish ✅
- Settings window (⌘,) with seven pages: General (menu bar icon, playlist behaviour, sleep),
  Local Collection (folders with per-folder watching, update and rescan), Metadata (automatic
  cover fetching, statistics in files, Apple Music import, Wikipedia language), Playback (M6),
  Notifications (OSD and Notification Center), Internet (podcast schedule and folder, the online
  services used, clearing the web cache) and Shortcuts (global shortcut recorders with defaults).
- On-screen display: a non-activating panel showing cover, title, artist/album, rating and length
  on track changes, plus pause/stop, volume, mute, rating and stop-after messages. Duration, text
  size and colour, translucency, screen, hiding during full-screen apps, and a draggable preview
  to place it. (The snapshot run caught a sizing bug that made it 0×0; fixed.)
- Menu bar icon: click shows or hides the window, right-click opens playback controls, scrolling
  changes the volume, middle-click pauses, tooltip shows the track.
- Global shortcuts (KeyboardShortcuts): ⌃⌥P play/pause, ⌃⌥←/→ previous/next, ⌃⌥=/− volume,
  ⌃⌥M mute, ⌃⌥O show OSD, ⌃⌥1–5 rate, ⌃⌥⇧V stop after current, ⌃⌥A add media; Stop unassigned.
- Optional Notification Center banners (with cover) while Amamac is in the background; a sleep
  assertion while playing and pause before sleep; "start playing when adding while stopped",
  "keep the playing track in view" and "fetch missing covers" now do what they say.
- App icon drawn by `scripts/make-icon.swift`: an original loudspeaker on coral, chosen from six designs
  (`make icon`; `swift scripts/make-icon.swift --preview DIR` renders all of them side by side).
- Neon-orange accent (`AccentColor` asset, also the global accent colour; `NSColor.amamacAccent` for
  custom drawing): play button, seek bar, volume dial, playing row, Analyzer and highlights.
- `make dmg`: Release build in a compressed disk image with an Applications shortcut and volume icon.
- About panel, Help window (layout, filter syntax, keys), Diagnostics (copyable report) and
  Acknowledgements; THIRD_PARTY_NOTICES.md generated from the packages' license files
  (`make notices`) and bundled in the app; README.md.
- Performance pass on 20,000 tracks (`make perf`, Debug build, this Mac):

  | Operation | Time |
  |---|---|
  | Collection top level / expand 5 artists | 43 ms / 17 ms |
  | Collection filter (“night”, `rating:>3 year:>1990`) | 48 ms / 36 ms |
  | Load 20,000 tracks with statistics | 208 ms |
  | Replace playlist with 20,000 items (incl. table) | 110 ms |
  | Sort by artist, album / clear | 87 ms / 38 ms |
  | Remove 5,000 items / undo | 58 ms / 61 ms |
  | Save / restore session | 47 ms / 348 ms |

  Random Albums with Favor rebuilt its album index on every step (≈10 ms per advance); it is now
  cached until the playlist changes (50 advances: 480 → 28 ms), and Favor now weights albums too.

## Refactor — modules ✅
- The core moved into the local package `Packages/AmamacKit` and was split into eleven modules
  (Base, Models, Query, Database, Library, Playlist, Dynamic, Playback, Web, Podcasts,
  TestSupport) whose imports the compiler checks. Cycles inside the old core were broken first:
  `PlaylistItem` and the file formats moved to Models, SQL generation to Database, `SplitMix64` and
  the duplicated hashing, XML and time helpers to Base.
- The app no longer runs SQL or imports GRDB; `LibraryDatabase.writer` is package-only and the app
  uses named methods and `StatisticsStore`.
- `AppEnvironment.shared` and `AppDelegate.shared` are gone. `AppDelegate` keeps the lifecycle;
  menu commands live in `App/Commands` controllers, Now Playing and session saving in their own
  controllers, navigation behind `AppRouter`, shared actions in `LibraryActions`, and the stores
  are built once. Grab-bag files were split per feature and shared UI pieces moved to `Shared/`.
- Debug runners and TestSupport are compiled only in Debug; the Release binary contains none of them.
- Behaviour, UI, data format and settings are unchanged: the schema and cache-name tests pin the
  persisted formats, and the snapshot run gained a check that all menu commands still reach their
  controllers.

