# Computer.js Runtime (macOS) — Milestone 1

This small local server lets websites call real macOS features (screen capture, mouse, keyboard, apps, files) — after you approve each capability.

## Install (one time)

1. Double-click **Install.command** — it creates a Python virtualenv and installs dependencies.
   (Requires Python 3 from https://www.python.org/downloads/)
2. The first time you start it, macOS asks for **Accessibility** and **Screen Recording**:
   System Settings → Privacy & Security → enable it for your terminal.

## Run

1. Double-click **Start Runtime.command** — it listens on `ws://127.0.0.1:8787/ws`.
2. Open the live demo at https://3x-haust.github.io/computer-js/examples/demo.html
   (or any site using the Computer.js SDK).
3. Click **Connect**, then **Grant everything**, approve the native dialog — done.

## What it does

| Capability | macOS mechanism |
|---|---|
| Mouse move/click/scroll | PyAutoGUI / CGEvent |
| Keyboard type/press/hotkey | PyAutoGUI |
| Screen capture | pyautogui screenshot + screencapture |
| Apps open | `open` / AppleScript launch |
| Files reveal/open | Finder open |
| Clipboard read/write | AppleScript / pbcopy |

## Security model (Milestone 1)

- Listens on `127.0.0.1` only (loopback).
- All capabilities are denied until the user grants them.
- Strong capabilities (screen, mouse, keyboard, clipboard read) always show a native macOS approval dialog.
- Grants persist per-origin in `grants.db` next to the runtime — revocable from the demo page.
- This is a dev milestone: no TLS, no code signing, local-only transport.

## Uninstall

Delete this folder. That's it.
