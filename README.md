# Amamac

A native music player for macOS on Apple silicon with the layout and features of
[Amarok](https://amarok.kde.org) 2/3: Media Sources on the left, the Context view in the middle
and the album-grouped Playlist on the right, under the Main Toolbar.

Amamac is an independent project, not affiliated with KDE. It rebuilds Amarok's documented
behaviour in Swift and contains no Amarok code, data or artwork.

## Features

- **Collection**: watched folders, fast incremental scans, Amarok's filter language
  (`artist:beatles year:>1990 -live`, `rating:>3.5`, `added:<2w`), configurable grouping, covers,
  ratings, scores and play counts, Edit Track Details with MusicBrainz lookup, Organize Files,
  Cover Manager, statistics import from Apple Music.
- **Playback**: gapless, FLAC, ALAC, AAC, MP3, Ogg Vorbis, Opus, WavPack, Musepack, TTA, DSD,
  modules and more (via SFBAudioEngine); 10-band equalizer with presets; ReplayGain; fades; output
  device choice; media keys and Now Playing.
- **Playlist**: album grouping and four layouts, multi-level sort, progressive search, queue,
  stop-after, undo, track progressions (repeat, random tracks/albums with Favor), saved
  playlists, M3U/PLS/XSPF/ASX, dynamic playlists with biases, the Automated Playlist Generator.
- **Context**: Current Track, Albums, Wikipedia and a spectrum Analyzer with seven styles.
- **Internet**: internet radio from radio-browser.info, podcasts with downloads and OPML.
- **Desktop**: on-screen display, menu bar icon, global shortcuts, notifications, bookmarks and
  `amamac://` links, a Files browser.

## Building

Requirements: macOS 26 or later on Apple silicon, Xcode 27, and XcodeGen
(`brew install xcodegen`).

```bash
make project      # generate Amamac.xcodeproj from project.yml
make build        # Debug build (log in build/last-build.log)
make run          # build and open the app
make app          # copy Amamac.app to build/
```

Release builds: `make app CONFIG=Release`. The app is signed ad hoc ("Sign to Run Locally"), so
macOS may ask again for access to Music, Documents or external drives after each rebuild.

## Installing

`make dmg` builds Release and writes `build/Amamac-<version>.dmg`; open it and drag Amamac onto
Applications. Disk images of older versions move to `archive/`, which `make clean` leaves alone.
A disk image built on your own Mac opens without warnings; copied to another Mac, the
ad-hoc signature means Gatekeeper blocks the first launch until you allow it in System Settings ›
Privacy & Security.

## Testing

```bash
make test         # core unit tests (no network; online clients use canned responses)
make test-engine  # real playback through the default output device, muted
make snapshot     # renders the window, panes and dialogs to $TMPDIR/amamac-snapshot
make perf         # times collection, playlist and session work on 20,000 tracks
```

## Where things live

- Library database, playlists and settings: `~/Library/Application Support/Amamac/`
- Web cache (Wikipedia, cover lookups): `~/Library/Application Support/Amamac/Caches/http`
- Podcast downloads: `~/Music/Podcasts/<podcast>` (changeable in Settings › Internet)

## Privacy

Amamac has no accounts and no analytics. Lookups go to Wikipedia/Wikidata, MusicBrainz, the
Cover Art Archive, the iTunes Search API and radio-browser.info, sending only titles, artists
and album names, with the User-Agent `Amamac/<version> (macOS music player)`.

## Licenses

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the components Amamac uses and their
licenses (also under Help › Acknowledgements). `make notices` regenerates it and `make icon`
redraws the app icon.
