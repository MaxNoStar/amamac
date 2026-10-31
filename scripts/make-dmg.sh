#!/bin/bash
# Packs a built Amamac.app into a compressed disk image for drag-to-install: the app, a shortcut to
# /Applications and the app icon as the volume icon. `make dmg` builds Release and calls it.
#   scripts/make-dmg.sh APP OUTPUT_DIR   → OUTPUT_DIR/Amamac-<version>.dmg
set -euo pipefail

APP="${1:?usage: make-dmg.sh APP OUTPUT_DIR}"
OUT_DIR="${2:?usage: make-dmg.sh APP OUTPUT_DIR}"
NAME=Amamac
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$OUT_DIR/$NAME-$VERSION.dmg"

# Refuse to package an app whose signature is broken; it would not launch after installing.
codesign --verify --deep --strict "$APP"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/amamac-dmg.XXXXXX")
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach -quiet "$MOUNT" || hdiutil detach -quiet -force "$MOUNT" || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

STAGE="$WORK/stage"
mkdir "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

# Build read-write first so the volume can be flagged as having a custom icon, then compress.
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW "$WORK/rw.dmg"
MOUNT=$(diskutil image attach --mountOptions nobrowse "$WORK/rw.dmg" | awk -F'\t' '/\/Volumes\// { print $NF }')
xcrun SetFile -a C "$MOUNT"
hdiutil detach -quiet "$MOUNT"
MOUNT=""

mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -o "$DMG"
hdiutil verify -quiet "$DMG"
echo "$DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
