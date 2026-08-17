#!/bin/bash
# Computer.js Runtime — start the local server (macOS)
# Serves ws://127.0.0.1:8787/ws so websites can control your Mac.
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"

if [ ! -x "$DIR/.venv/bin/python" ]; then
  echo "✗ Not installed yet. Double-click  Install.command  first."
  read -p "Press Enter to close…" _
  exit 1
fi

echo "── Computer.js Runtime ────────────────────────────────────"
echo "  Listening on ws://127.0.0.1:8787/ws"
echo "  Grant Accessibility + Screen Recording in System Settings on first use."
echo "  Press Ctrl+C to stop. Close this window to quit."
echo ""

exec "$DIR/.venv/bin/python" "$DIR/runtime.py" --port 8787 --allow "http://localhost:3000" --allow "https://3x-haust.github.io"
