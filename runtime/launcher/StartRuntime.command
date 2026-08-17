#!/bin/bash
# Computer.js Runtime — start the local server (macOS)
# Serves the demo at http://127.0.0.1:8787/ and the WebSocket at ws://127.0.0.1:8787/ws
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"

if [ ! -x "$DIR/.venv/bin/python" ]; then
  echo "✗ Not installed yet. Double-click  Install.command  first."
  read -p "Press Enter to close…" _
  exit 1
fi

echo "── Computer.js Runtime ────────────────────────────────────"
echo "  Demo:    http://127.0.0.1:8787/"
echo "  WebSocket: ws://127.0.0.1:8787/ws"
echo "  Grant Accessibility + Screen Recording in System Settings on first use."
echo "  Press Ctrl+C to stop. Close this window to quit."
echo ""

"$DIR/.venv/bin/python" "$DIR/runtime.py" --port 8787 \
  --allow "http://127.0.0.1:8787" \
  --allow "http://localhost:3000" \
  --allow "https://3x-haust.github.io" &
RUNTIME_PID=$!

# wait for the server to come up
for i in $(seq 1 20); do
  if curl -s -o /dev/null http://127.0.0.1:8787/health; then
    break
  fi
  sleep 0.5
done

open "http://127.0.0.1:8787/" || true
wait $RUNTIME_PID
