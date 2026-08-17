#!/bin/bash
# Build ComputerRuntime.app bundle from the Swift build product.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
APP="$DIR/dist/Computer.js Runtime.app"
BIN="$DIR/.build/release/ComputerRuntime"
if [ ! -f "$BIN" ]; then
  echo "release binary missing — building"
  (cd "$DIR" && swift build -c release)
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/www"
cp "$BIN" "$APP/Contents/MacOS/ComputerRuntime"
# bundle the control panel (web/) into Resources/www
cp -R "$ROOT/web/." "$APP/Contents/Resources/www/"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Computer.js Runtime</string>
	<key>CFBundleDisplayName</key><string>Computer.js Runtime</string>
	<key>CFBundleIdentifier</key><string>dev.computerjs.runtime</string>
	<key>CFBundleVersion</key><string>0.2.0</string>
	<key>CFBundleShortVersionString</key><string>0.2.0</string>
	<key>CFBundleExecutable</key><string>ComputerRuntime</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSHumanReadableCopyright</key><string>Computer.js</string>
</dict>
</plist>
PLIST

echo "Built: $APP"