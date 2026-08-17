# Computer.js — Web API for your computer

> **웹사이트가 사용자의 허가를 받아 실제 컴퓨터 기능을 호출한다.**
> Websites call real macOS features (screen, mouse, keyboard, apps, files) after the user approves — through a local, native **Computer Runtime**.

## What this is

- **Native macOS app** (Swift + AppKit, no Electron, no Python) — a menu-bar agent that:
  - serves a **real control panel** at `http://127.0.0.1:8788/` (screenshot studio, clipboard center, app launcher, file tools, typing, hotkeys)
  - exposes a **WebSocket JSON-RPC API** at `ws://127.0.0.1:8787/ws`
  - enforces **per-origin, per-capability permissions** with **native macOS approval dialogs**
- **TypeScript Web SDK** — the `computer.*` API any website can use
- **Distributed as a DMG** (ad-hoc code-signed)

```
┌─────────────────────┐  WebSocket   ┌──────────────────────────────┐
│  Control panel / SDK │ ───────────► │  Computer.js Runtime (.app)  │
│  (my browser)        │   JSON-RPC    │  Swift · AppKit · native     │
└─────────────────────┘               └──────────────┬───────────────┘
                                                     │
                                      macOS APIs: ScreenCaptureKit,
                                      CGEvent, NSWorkspace, NSPasteboard
```

## Install (DMG)

1. Download the latest `.dmg` from **Releases**.
2. Open it and drag **Computer.js Runtime.app** to Applications.
3. Launch it (right-click → Open the first time; it's ad-hoc signed).
4. The control panel opens at **http://127.0.0.1:8788/** automatically.
5. Grant **Accessibility** + **Screen Recording** in System Settings when prompted.

## What the control panel does

| Tool | Capability | macOS mechanism |
|---|---|---|
| 📸 Screenshot studio | full-screen / window capture + download, copy | ScreenCaptureKit |
| 📋 Clipboard center | read / write / save clipboard | NSPasteboard |
| 🚀 App launcher | open any app by name or bundle id | NSWorkspace |
| 📁 Files & folders | reveal in Finder, open default app | NSWorkspace |
| ⌨️ Type & shortcuts | type text, press hotkeys (⌘⇥, ⌘Space, ⌘C…) | CGEvent |

Every capability is **denied until you grant it**. Strong ones (screen, mouse, keyboard, clipboard read) always show a native approval dialog.

## Layout

```
native/    Swift runtime (Package.swift) → build script → .app → .dmg
sdk/       TypeScript Web SDK (@computerjs/sdk) → ESM + browser IIFE bundle
web/       Control panel (index.html) served by the Runtime at :8788
```

## Building the app & DMG

```bash
cd native
swift build -c release
bash Scripts/make_app.sh                    # builds .app with bundled control panel
codesign --force --deep --sign - "dist/Computer.js Runtime.app"
hdiutil create -volname "Computer.js Runtime" \
  -srcfolder "dist/Computer.js Runtime.app" -ov -format UDZO \
  "dist/Computerjs-Runtime-v0.2.0.dmg"
```

## Tests

```bash
cd sdk && COMPUTER_RUNTIME_AUTO_APPROVE=1 node e2e.test.mjs   # against running app
```

## Scope & honest limitations (v0.2.0)

- **Local-only** transport on loopback; no TLS, no code signing identity, no notarization.
- Coordinate-based input via CGEvent (the product roadmap calls for AXUIElement / UI Automation).
- The control panel is served by the Runtime itself — a hosted page on `github.io` **cannot** reach your localhost due to Chrome Local Network Access rules (by design).
- Ad-hoc code signature: macOS will warn on first open. Full release needs a Developer ID + notarization.
