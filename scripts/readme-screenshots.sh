#!/bin/bash
# Renders the README screenshots from the made-up showcase library (never your own music): runs
# the Debug app's snapshot mode with AMAMAC_SNAPSHOT_SHOWCASE=1 in light and dark, then resizes
# the 2× captures into OUT_DIR/<name>-<light|dark>.png. `make screenshots` calls it.
#   scripts/readme-screenshots.sh APP [OUT_DIR]
set -euo pipefail

APP="${1:?usage: readme-screenshots.sh APP [OUT_DIR]}"
OUT="${2:-docs/images/screenshots}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/amamac-showcase.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# capture name | width in the README image (pixels; about 2× the width it is shown at)
SHOTS=(
  "hero|1600"
  "context|800"
  "collection|520"
  "analyzer-aurora|800"
  "analyzer-halo|800"
  "analyzer-ledMatrix|800"
  "dynamic|520"
  "radio|520"
  "settings|560"
)

for theme in light dark; do
  dir="$WORK/$theme"
  mkdir -p "$dir"
  if [ "$theme" = dark ]; then export AMAMAC_SNAPSHOT_DARK=1; else unset AMAMAC_SNAPSHOT_DARK; fi
  if ! AMAMAC_SNAPSHOT_SHOWCASE=1 "$APP/Contents/MacOS/Amamac" --snapshot "$dir" --data-dir "$dir/data" > "$dir/log.txt" 2>&1; then
    tail -20 "$dir/log.txt" >&2
    exit 1
  fi
  for shot in "${SHOTS[@]}"; do
    IFS='|' read -r name width <<<"$shot"
    src="$dir/showcase-$name.png" dst="$OUT/$name-$theme.png"
    current=$(sips -g pixelWidth "$src" | awk '/pixelWidth/ { print $2 }')
    if [ "$current" -gt "$width" ]; then
      sips --resampleWidth "$width" "$src" --out "$dst" > /dev/null
    else
      cp "$src" "$dst"
    fi
  done
  echo "$theme: done"
done
du -ch "$OUT"/*.png | tail -1 | sed 's/total/screenshots in total/'
