# Amamac

Native macOS (Apple Silicon) music player that reproduces Amarok 2/3's layout and features.
No Amarok code, data tables, or artwork is copied; behaviour is reimplemented from documentation.

## Commands
- `make project` — regenerate `Amamac.xcodeproj` from `project.yml` (the project file is git-ignored).
- `make build` — Debug build; full log in `build/last-build.log`, only errors are printed.
- `make test` — core unit tests (Swift Testing), excluding the audio engine suite.
- `make test-engine` — audio engine tests (muted, serialized).
- `make run` — build and open the app.
- `make dmg` — Release build packed into `build/Amamac-<version>.dmg` (`scripts/make-dmg.sh`); disk images of
  older versions move to `archive/` (git-ignored, outside `build/` so `make clean` keeps it).
- `make snapshot` — run the app offscreen with `--snapshot <dir> --data-dir <dir>/data --dump-layout`
  and write PNGs + `layout.json` to `$TMPDIR/amamac-snapshot`.
- `make screenshots` — README screenshots from the made-up showcase library (`AMAMAC_SNAPSHOT_SHOWCASE=1`),
  light and dark, resized into `docs/images/screenshots/` (`scripts/readme-screenshots.sh`).
- `make mascot` — re-render the mascot PNGs and the social preview from the SVGs in `docs/images/mascot/`.
- `make resolve` — re-resolve SwiftPM packages and refresh the committed `Package.resolved`.

DerivedData lives in `~/Library/Developer/Xcode/DerivedData/Amamac-cli` (not inside `~/Documents`).

## Layout
- `Packages/AmamacKit` — local Swift package, default isolation **nonisolated**, one module per layer.
  Modules link statically into the app; a module may only import the ones it lists in `Package.swift`
  (the table names the nearest layers):

  | Module | Contents | Builds on |
  |---|---|---|
  | `AmamacBase` | text folding, time formatting, hashing, XML escaping, `SplitMix64`, `Amamac` (version, User-Agent) | — |
  | `AmamacModels` | `Track`, `TagChanges`, `PlaylistItem`, file formats, `AmamacLink` | Base |
  | `AmamacQuery` | filter language: parser, AST, dates, in-memory matching | Base, Models |
  | `AmamacDatabase` | `LibraryDatabase` (`writer` is package-only), migrations `"v1"` (as shipped) and `"v2"` (drops lyrics), records, collection queries, query → SQL | Query, GRDB |
  | `AmamacLibrary` | scanner, watcher, tags, editing, Organize, covers, statistics (`StatisticsStore`) | Database, SFBAudioEngine |
  | `AmamacPlaylist` | model, proxy, navigator, layouts, playlist files, session, saved playlists, bookmarks | Library |
  | `AmamacDynamic` | biases, dynamic playlists, the generator, `GeneratorStore` | Query, Database |
  | `AmamacPlayback` | local engine (two decks for crossfades) and stream engine, engine bridge, crossfader, ReplayGain, EQ, devices, spectrum tap, analyzer bar dynamics | Models, SFBAudioEngine |
  | `AmamacWeb` | `HTTPClient`, Wikipedia, MusicBrainz and covers, radio-browser | Database |
  | `AmamacPodcasts` | feeds, OPML, `PodcastService`, directory | Web, FeedKit |
  | `AmamacTestSupport` | audio fixtures, synthetic library, `StubURLProtocol`, in-memory database; compiled only in Debug | Library |
- `Sources/Amamac` — app, default isolation **MainActor**, one folder per feature:
  `App` (lifecycle, `AppEnvironment`, `AppRouter`, `LibraryActions`, menu command controllers in
  `App/Commands`, desktop integration in `App/Desktop`), `MainWindow`, `MediaSources`, `Context`,
  `Playlist`, `Dialogs`, `Settings`, `Shared` (UI pieces several features use) and `Debug`
  (snapshot, perf and self-test runners; compiled only in Debug).
- `Tests/AmamacKitTests` — Swift Testing, `@testable import` per module; fixtures are generated
  under `$TMPDIR` at test time.

## Working rules (all future work stays modular)
- A new feature gets its own file or folder; one main type per file, no grab-bag files.
- Logic that needs no UI goes into the matching AmamacKit module, with tests in
  `Tests/AmamacKitTests`; the app keeps only views, controllers and wiring.
- Split a file along its type boundaries once it grows past ~400 lines.
- Plan changes layer by layer (core module → app feature folder → docs), one commit per layer.
- Outside data (tags, playlist files, feeds, HTTP headers, `amamac://` links) never reaches a force
  unwrap, `Int(Double)`, `Dictionary(uniqueKeysWithValues:)`, unchecked arithmetic or a file path
  directly: use `SafeNumbers`, `PathComponent`, `Paths` and `URL.isWebURL` from AmamacBase.

## App structure rules
- The app never runs SQL or imports GRDB: database work goes through `LibraryDatabase` methods and
  the stores (`StatisticsStore`, `BookmarkStore`, …), which `AppEnvironment` builds once.
- No global singletons: windows, panes and dialogs get the `AppEnvironment`; navigation goes
  through `env.router` (`AppRouter`), shared actions through `env.actions` (`LibraryActions`).
- Menu items keep a nil target. Their actions live in the `App/Commands` controllers, which
  `AppDelegate` forwards to at the end of the responder chain; `make snapshot` checks every one.
- Automation options (`--snapshot`, `--perf`, `--selftest-decoders`, `--canary`) exist only in
  Debug builds; Release honours `--data-dir` only.

## Concurrency rules
- In the app target every closure literal is inferred `@MainActor`. Closures that the system calls
  off-main (audio taps, `MPMediaItemArtwork`, NotificationCenter `queue: nil`, FSEvents, URLSession
  delegates, AVPlayerItemMetadataOutput) must be created in a `nonisolated` function in Core or be
  explicitly `@Sendable`.
- Records / Codable / settings DTOs live in Core (or are `nonisolated struct`).
- CPU-heavy Core entry points are `@concurrent`.
- `@preconcurrency import` of SFBAudioEngine / AVFoundation / MediaPlayer only in engine files.
- The engine bridge enqueues the next track synchronously inside `decodingComplete` — never hop to
  the main actor for gapless decisions. The main actor pushes `upcoming` after every playlist change.
- The crossfader starts the next deck on its own queue from the same `upcoming` (whichever takes it
  first wins) — never hop to the main actor for crossfade timing either.

## Data / privacy
- App data: `~/Library/Application Support/Amamac/` (override with `--data-dir`).
- HTTP cache: `<app data>/Caches/http`, pruned to 30 days at launch.
- Never delete tracks whose collection root is unreachable.
- Tag writes go to a temp copy and are swapped in with `FileManager.replaceItemAt`.

## Progress
See `docs/PROGRESS.md`.
