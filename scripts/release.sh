#!/bin/bash
#
# release.sh — build + version + publish a Computer.js release.
#
# Usage:
#   release.sh [patch|minor|major] ["optional human note"]
#
# Bumps the version, rebuilds the app + DMG, signs it, and publishes a GitHub
# release with a fresh version tag. Release notes are auto-generated from the
# git commits since the previous tag, plus your optional note.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/native"
VERSION_FILE="$NATIVE/Sources/ComputerRuntime/Version.swift"
REPO="3x-haust/computer-js"
note="${2:-}"

bump="${1:-patch}"
echo "=== Computer.js release (bump: $bump) ==="

# --- read current version ---
cur="$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' "$VERSION_FILE" | head -1 | tr -d '"')"
if [ -z "$cur" ]; then echo "✗ cannot read current version from $VERSION_FILE"; exit 1; fi
IFS='.' read -r major minor patch <<< "$cur"
case "$bump" in
  major) major=$((major+1)); minor=0; patch=0 ;;
  minor) minor=$((minor+1)); patch=0 ;;
  patch) patch=$((patch+1)) ;;
  *) echo "✗ unknown bump: $bump (patch|minor|major)"; exit 1 ;;
esac
new="$major.$minor.$patch"
echo "  version: $cur → $new"

# --- write new version constant (also updates Server/Capabilities via this file) ---
sed -i.bak "s/\"$cur\"/\"$new\"/g" "$VERSION_FILE"
rm -f "$VERSION_FILE.bak"

# --- rebuild release app + DMG ---
echo "  building release app…"
(cd "$NATIVE" && swift build -c release)
(cd "$NATIVE" && bash Scripts/make_app.sh)
echo "  code-signing…"
codesign --force --deep --sign - "$NATIVE/dist/Computer.js Runtime.app"
echo "  building DMG…"
(cd "$NATIVE" && bash Scripts/make_dmg.sh)
DMG="$NATIVE/dist/Computerjs-Runtime-v$new.dmg"
test -f "$DMG" || { echo "✗ DMG not found at $DMG"; exit 1; }

# --- build release notes from commits since last tag ---
last_tag="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || echo "v0.1.0-milestone1")"
log="$(git -C "$ROOT" log --oneline "$last_tag"..HEAD 2>/dev/null | sed 's/^/  - /' | head -40)"
notes="# Computer.js Runtime v$new\n\n## What's new\n$log\n\n## Install\n1. Open the DMG\n2. Drag **Computer.js Runtime.app** onto the **Applications** shortcut\n3. Launch it (right-click → Open the first time; ad-hoc signed) — control panel at http://127.0.0.1:8788/\n\n## Download\n- **Computerjs-Runtime-v$new.dmg**"
if [ -n "$note" ]; then
  notes="$notes\n\n---\n\n$note"
fi

echo ""
echo "=== publishing release v$new ==="
gh release create "v$new" "$DMG" \
  --repo "$REPO" \
  --title "Computer.js Runtime v$new" \
  --notes "$notes"

echo "✓ Released: https://github.com/$REPO/releases/tag/v$new"
echo "  DMG: $DMG"
