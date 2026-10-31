#!/bin/bash
# Writes THIRD_PARTY_NOTICES.md (and a copy bundled with the app) from the license files of the
# resolved Swift packages. Run after `make resolve`; `make notices` calls it.
set -euo pipefail

CHECKOUTS="${CHECKOUTS:-$HOME/Library/Developer/Xcode/DerivedData/Amamac-cli/SourcePackages/checkouts}"
OUT="${1:-THIRD_PARTY_NOTICES.md}"

# package directory | display name | license | what it does in Amamac
PACKAGES=(
  "SFBAudioEngine|SFBAudioEngine|MIT|Audio decoding, gapless playback and tag reading/writing"
  "AVFAudioExtensions|AVFAudioExtensions|MIT|Part of SFBAudioEngine"
  "CXXAudioRingBuffer|CXXAudioRingBuffer|MIT|Part of SFBAudioEngine"
  "CXXDispatchSemaphore|CXXDispatchSemaphore|MIT|Part of SFBAudioEngine"
  "CXXMessageQueue|CXXMessageQueue|MIT|Part of SFBAudioEngine"
  "CXXQueue|CXXQueue|MIT|Part of SFBAudioEngine"
  "CXXUnfairLock|CXXUnfairLock|MIT|Part of SFBAudioEngine"
  "CXXTagLib|TagLib|LGPL-2.1 or MPL-1.1|Tag reading and writing"
  "CXXMonkeysAudio|Monkey's Audio SDK|BSD-3-Clause|APE decoding"
  "CDUMB|DUMB|DUMB licence (zlib-style)|Module (MOD, S3M, XM, IT) decoding"
  "CSpeex|Speex|BSD-3-Clause|Speex decoding"
  "ogg-binary-xcframework|libogg|BSD-3-Clause|Ogg container"
  "flac-binary-xcframework|libFLAC|BSD-3-Clause|FLAC decoding"
  "opus-binary-xcframework|libopus|BSD-3-Clause|Opus decoding"
  "vorbis-binary-xcframework|libvorbis|BSD-3-Clause|Vorbis decoding"
  "wavpack-binary-xcframework|WavPack|BSD-3-Clause|WavPack decoding"
  "mpc-binary-xcframework|libmpcdec (Musepack)|BSD-3-Clause and LGPL-2.1|Musepack decoding"
  "mpg123-binary-xcframework|mpg123|LGPL-2.1|MP3 decoding"
  "lame-binary-xcframework|LAME|LGPL-2.0|MP3 encoding support in SFBAudioEngine"
  "sndfile-binary-xcframework|libsndfile|LGPL-2.1|WAV/AIFF and other PCM formats"
  "tta-cpp-binary-xcframework|TTA|LGPL-3.0|True Audio decoding"
  "GRDB.swift|GRDB.swift|MIT|SQLite database"
  "FeedKit|FeedKit|MIT|Podcast feed parsing"
  "KeyboardShortcuts|KeyboardShortcuts|MIT|Global keyboard shortcuts"
)

{
  echo "# Third-Party Notices"
  echo
  echo "Amamac is built on the open-source components below. Amamac itself contains no code, data or"
  echo "artwork from Amarok; it reproduces Amarok's layout and behaviour from its documentation."
  echo
  echo "The LGPL-licensed libraries (LAME, mpg123, libsndfile, TTA and parts of Musepack) are"
  echo "dynamically linked frameworks inside \`Amamac.app/Contents/Frameworks\` and can be replaced"
  echo "with modified builds. Their sources are available from the upstream projects and from the"
  echo "corresponding \`*-binary-xcframework\` repositories at https://github.com/sbooth."
  echo
  echo "| Component | License | Used for |"
  echo "|---|---|---|"
  for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r dir name license purpose <<<"$entry"
    echo "| $name | $license | $purpose |"
  done
  echo
  echo "Online services used at run time (no accounts, no personal data): Wikipedia and Wikidata,"
  echo "MusicBrainz, the Cover Art Archive, the iTunes Search API and radio-browser.info."
  echo
  echo "## License texts"
  for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r dir name license purpose <<<"$entry"
    echo
    echo "### $name"
    echo
    for file in $(ls "$CHECKOUTS/$dir" | grep -iE '^(license|copying)' | grep -v '^LICENSES$'); do
      echo '```'
      cat "$CHECKOUTS/$dir/$file"
      echo
      echo '```'
    done
  done
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
