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
## M3 — Context view
## M4 — Library management
## M5 — Playlists
## M6 — Audio extras
## M7 — Internet
## M8 — Desktop integration and polish
