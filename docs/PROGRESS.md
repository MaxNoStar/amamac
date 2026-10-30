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

## M1 — Core library
## M2a — Playable slice
## M2b — Playlist pane
## M2c — Window chrome
## M3 — Context view
## M4 — Library management
## M5 — Playlists
## M6 — Audio extras
## M7 — Internet
## M8 — Desktop integration and polish
