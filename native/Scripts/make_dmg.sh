#!/bin/bash
# Build a "drag to install" DMG: app icon + /Applications alias.
# The user opens the DMG, drags the app onto the Applications shortcut.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="$ROOT/native/dist"

APP="$DIST/Computer.js Runtime.app"
STAGE="$DIST/DMGContents"
DMG="$DIST/Computerjs-Runtime-v0.2.0.dmg"

if [ ! -d "$APP" ]; then
  echo "✗ Missing app bundle. Build it first with Scripts/make_app.sh"
  exit 1
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

# 1. Copy the app into the staging folder
cp -R "$APP" "$STAGE/"

# 2. Symlink to /Applications so the user can drag the app onto it
ln -s /Applications "$STAGE/Applications"

# 3. Create the DMG (UDZO = compressed, standard)
hdiutil create -volname "Computer.js Runtime" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null

# 4. Clean the staging dir
rm -rf "$STAGE"

echo "✓ Built drag-to-install DMG: $DMG"
ls -la "$DMG"