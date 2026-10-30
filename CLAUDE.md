# Amamac

Native macOS (Apple Silicon) music player that reproduces Amarok 2/3's layout and features.
No Amarok code, data tables, or artwork is copied; behaviour is reimplemented from documentation.

## Commands
- `make project` — regenerate `Amamac.xcodeproj` from `project.yml` (the project file is git-ignored).
- `make build` — Debug build; full log in `build/last-build.log`, only errors are printed.
- `make test` — core unit tests (Swift Testing), excluding the audio engine suite.
- `make test-engine` — audio engine tests (muted, serialized).
- `make run` — build and open the app.
- `make snapshot` — run the app offscreen with `--snapshot <dir> --data-dir <dir>/data --dump-layout`
  and write PNGs + `layout.json` to `$TMPDIR/amamac-snapshot`.
- `make resolve` — re-resolve SwiftPM packages and refresh the committed `Package.resolved`.

DerivedData lives in `~/Library/Developer/Xcode/DerivedData/Amamac-cli` (not inside `~/Documents`).

## Layout
- `Sources/AmamacCore` — framework, default isolation **nonisolated**: models, database (GRDB),
  scanner, query language, playback engines (SFBAudioEngine + AVPlayer), playlist logic, web clients.
- `Sources/Amamac` — app, default isolation **MainActor**: AppKit lifecycle, windows, panes, dialogs.
- `Tests/AmamacCoreTests` — Swift Testing; fixtures are generated under `$TMPDIR` at test time.

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

## Data / privacy
- App data: `~/Library/Application Support/Amamac/` (override with `--data-dir`).
- HTTP cache: `~/Library/Caches/Amamac/http`.
- Never delete tracks whose collection root is unreachable.
- Tag writes go to a temp copy and are swapped in with `FileManager.replaceItemAt`.

## Progress
See `docs/PROGRESS.md`.
