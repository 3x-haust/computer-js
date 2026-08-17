# Computer.js — Web API for your Mac

> **웹사이트가 사용자의 허가를 받아 실제 컴퓨터 기능을 호출한다.**
> A website calls real macOS features (screen, mouse, keyboard, apps, files) after the user approves — through a local **Computer Runtime**.

This is **Milestone 1**: a working end-to-end loop on macOS. A webpage uses a TypeScript SDK (`computer.*`) that talks JSON-RPC over WebSocket to a local Python Runtime, which drives the real OS via PyAutoGUI + native macOS tools.

```
┌─────────────┐   WebSocket   ┌──────────────────┐
│   Web SDK    │ ───────────► │   Runtime (local) │ ──► macOS
│  (browser)   │   JSON-RPC    │  python runtime.py │    PyAutoGUI, open,
└─────────────┘               └──────────────────┘    pbcopy, screencapture
         ▲                            ▲
         └── user approves in native dialog (strong caps)
```

## What works right now

| Group | Capability | Notes |
|---|---|---|
| Permissions | `permissions.query` / `request` / `revoke` | per-origin, persisted in `runtime/grants.db`; strong caps show a **native macOS dialog** |
| Screen | `screen.capture` | full-screen or frontmost window → PNG (base64) |
| Mouse | `mouse.move` / `click` / `scroll` | needs Accessibility |
| Keyboard | `keyboard.type` / `press` / `hotkey` | needs Accessibility |
| Apps | `apps.open` | bundle id, app name, or file path |
| Files | `files.reveal` / `open` | reveal in Finder, open default app |
| Clipboard | `clipboard.read` / `write` | read requires grant |

## Layout

```
sdk/        TypeScript Web SDK (@computerjs/sdk) -> dist/computer.js (ESM), computer.iife.js (global <script>)
runtime/    Python Runtime (aiohttp WebSocket + JSON-RPC server)
examples/   demo.html — the demo page that drives your Mac
```

## Quickstart

### 1. Start the Runtime

```bash
python3 -m pip install aiohttp pyautogui     # if not already installed
python3 runtime/runtime.py --port 8787
```

macOS will ask for **Accessibility** (mouse/keyboard) and **Screen Recording** (capture) permissions on first use. Grant them in **System Settings > Privacy & Security**.

### 2. Serve the demo

```bash
python3 -m http.server 3000
```

### 3. Open the demo

Open **http://localhost:3000/examples/demo.html**, click **Connect**, then **Grant everything** (approve the native dialog), then click the action buttons — watch your cursor move and your screen capture.

## Using the SDK in your own page

Via a plain `<script>` tag:

```html
<script src="/sdk/dist/computer.iife.js"></script>
<script>
  await window.computer.connect({ url: "ws://127.0.0.1:8787/ws" });
  await window.computer.permissions.request(["screen.capture", "mouse.move"]);
  const shot = await window.computer.screen.capture();
  const img = "data:image/png;base64," + shot.data;
</script>
```

As an ES module:

```ts
import { computer } from "@computerjs/sdk";
await computer.connect();
await computer.permissions.request(["apps.open"]);
await computer.apps.open({ id_or_path: "com.apple.Safari" });
```

## Rebuilding the SDK

```bash
cd sdk && npm install && npm run build
```

## Tests

```bash
cd runtime && python3 smoke_test.py      # runtime: permission gate, actions, errors
cd sdk && node e2e.test.mjs              # built SDK bundle → live runtime → real OS
```

Both pass against a running Runtime on `127.0.0.1:8787`.

## Scope & honest limitations (Milestone 1)

- **Local-only**: connects straight to `127.0.0.1` (no Relay server, no pairing challenge, no E2E encryption). That's the explicit next milestone.
- **Keyboard/mouse** are coordinates via PyAutoGUI; the product spec correctly wants AXUIElement / UI Automation later.
- **Permission UX** uses an AppleScript `display dialog`. A real Runtime should draw its own native approval window.
- **Not production**: no code signing, no packaging.

For the full product roadmap, security threat model, and OS matrix, see `computer-js-name-and-implementation-guide.md`.
