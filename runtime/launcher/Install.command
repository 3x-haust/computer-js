#!/bin/bash
# Computer.js Runtime — one-time install (macOS)
# Creates a Python virtualenv and installs the runtime's dependencies.
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"

echo "── Computer.js Runtime installer ───────────────────────────"
echo ""

# locate Python 3
if command -v python3 >/dev/null 2>&1; then
  PY=python3
else
  echo "✗ Python 3 not found. Install it from https://www.python.org/downloads/ and retry."
  read -p "Press Enter to close…" _
  exit 1
fi

echo "Using $($PY --version)"
echo "Creating virtual environment…"
$PY -m venv "$DIR/.venv"

echo "Installing dependencies (aiohttp, pyautogui)…"
"$DIR/.venv/bin/pip" install --quiet --upgrade pip
"$DIR/.venv/bin/pip" install --quiet aiohttp pyautogui

echo ""
echo "✓ Installed. Now double-click  Start Runtime.command"
echo ""
read -p "Press Enter to close…" _
