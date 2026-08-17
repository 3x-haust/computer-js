#!/usr/bin/env python3
"""
Computer.js - macOS Computer Runtime (Milestone 1)

A local WebSocket + JSON-RPC 2.0 server that lets a webpage call real
macOS features (mouse, keyboard, screen capture, app/file open) after a
one-time user-approved permission grant shown in a native dialog.

Run:
    python3 runtime.py [--port 8787] [--allow http://localhost:3000]

Requires:
    python3 -m pip install aiohttp pyautogui
    (macOS will prompt for Accessibility / Screen Recording on first use)
"""

import argparse
import asyncio
import base64
import inspect
import io
import json
import logging
import os
import sqlite3
import subprocess
import time
from pathlib import Path

import aiohttp
from aiohttp import web

log = logging.getLogger("computer-runtime")

# ---------------------------------------------------------------------------
# Capability catalog: name -> (risk, is_strong)
# ---------------------------------------------------------------------------
# is_strong = True means a native approval dialog is required, not just a
# one-time grant request.
CAPABILITIES = {
    "runtime.status":      ("low",  False),
    "permissions.query":   ("low",  False),
    "permissions.request": ("low",  False),
    "permissions.revoke":  ("low",  False),
    "screen.capture":      ("med",  True),   # Screen Recording permission
    "mouse.move":          ("high", True),   # Accessibility permission
    "mouse.click":         ("high", True),
    "mouse.scroll":        ("high", True),
    "keyboard.type":       ("high", True),
    "keyboard.press":      ("high", True),
    "keyboard.hotkey":     ("high", True),
    "apps.open":           ("low",  False),
    "files.reveal":        ("low",  False),
    "files.open":          ("low",  False),
    "clipboard.read":      ("med",  True),
    "clipboard.write":     ("med",  False),
}

_ACTIONS = {}


def action(name):
    """Decorator registering a capability handler."""
    def wrap(fn):
        _ACTIONS[name] = fn
        return fn
    return wrap


# ---------------------------------------------------------------------------
# Persisted per-origin grants
# ---------------------------------------------------------------------------

class GrantStore:
    """Persist per-origin grants across runtime restarts."""

    def __init__(self, path):
        self._path = path
        self._conn = sqlite3.connect(path)
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS grants ("
            "origin TEXT PRIMARY KEY, capabilities TEXT, created REAL)"
        )
        self._conn.commit()

    def get(self, origin):
        row = self._conn.execute(
            "SELECT capabilities FROM grants WHERE origin=?", (origin,)
        ).fetchone()
        return {"origin": origin, "capabilities": json.loads(row[0]) if row else []}

    def set(self, origin, capabilities):
        self._conn.execute(
            "INSERT INTO grants (origin, capabilities, created) VALUES (?,?,?) "
            "ON CONFLICT(origin) DO UPDATE SET capabilities=excluded.capabilities",
            (origin, json.dumps(sorted(set(capabilities))), time.time()),
        )
        self._conn.commit()
        return self.get(origin)

    def revoke(self, origin):
        self._conn.execute("DELETE FROM grants WHERE origin=?", (origin,))
        self._conn.commit()
        return {"origin": origin, "capabilities": []}


# ---------------------------------------------------------------------------
# Native OS helpers
# ---------------------------------------------------------------------------

def osascript(script, timeout=60):
    """Run an osascript snippet. Returns (returncode, stdout)."""
    proc = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True, text=True, timeout=timeout,
    )
    return proc.returncode, proc.stdout.strip()


def native_confirm(origin, capabilities):
    """Show a real macOS approval dialog. Returns True when user clicks Allow."""
    risk_tier = {c: CAPABILITIES[c][0] for c in capabilities}
    lines = "\n".join(f"{c}   ({risk_tier[c]})" for c in sorted(capabilities))
    script = (
        'display dialog "'
        + f"{origin} wants to use these computer capabilities:\\n\\n{lines}\\n\\n"
        + 'Choose Allow to grant, or Deny to refuse." '
        + 'with title "Computer.js Runtime" '
        + 'buttons {"Deny", "Allow"} default button "Allow" with icon caution'
    )
    rc, out = osascript(script)
    return rc == 0 and "Allow" in out


def accessibility_trusted():
    """True when this process has macOS Accessibility permission."""
    try:
        import Quartz
        return bool(Quartz.AXIsProcessTrusted())
    except Exception:
        return None  # unknown: let the OS surface the prompt


def _map_key(key):
    keymap = {
        "ENTER": "enter", "RETURN": "enter", "ESC": "esc", "ESCAPE": "esc",
        "SPACE": "space", "TAB": "tab", "BACKSPACE": "backspace", "DELETE": "delete",
        "META": "command", "CMD": "command", "CTRL": "ctrl", "SHIFT": "shift",
        "ALT": "option", "OPTION": "option",
        "ARROW_UP": "up", "ARROW_DOWN": "down", "ARROW_LEFT": "left",
        "ARROW_RIGHT": "right",
    }
    return keymap.get(key.upper(), key.lower())


def frontmost_window_id():
    """Best-effort frontmost window number (needs Screen Recording later)."""
    try:
        import Quartz
        info = Quartz.CGWindowListCopyWindowInfo(
            Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID
        )
        for w in info:
            if w.get("kCGWindowLayer", 0) == 0:
                return w.get("kCGWindowNumber")
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# Capability implementations
# ---------------------------------------------------------------------------

@action("runtime.status")
def runtime_status():
    return {
        "server": "computer-runtime",
        "version": "0.1.0-milestone1",
        "os": "macos",
        "status": "running",
        "transport": "local-ws",
    }


@action("screen.capture")
def screen_capture(target="screen"):
    import pyautogui
    if target == "window":
        win_id = frontmost_window_id()
        if win_id is None:
            raise ValueError("Could not find a frontmost window")
        out = Path(tempfile_dir()) / f"computerjs-{int(time.time())}.png"
        subprocess.run(
            ["screencapture", "-x", "-o", "-l", str(win_id), str(out)],
            check=True,
        )
        with open(out, "rb") as f:
            b64 = base64.b64encode(f.read()).decode("ascii")
        size = screenshot_size(str(out))
        return {"width": size[0], "height": size[1], "format": "png", "data": b64}

    bitmap = pyautogui.screenshot()
    buf = io.BytesIO()
    bitmap.save(buf, format="PNG")
    return {
        "width": bitmap.width,
        "height": bitmap.height,
        "format": "png",
        "data": base64.b64encode(buf.getvalue()).decode("ascii"),
    }


def tempfile_dir():
    import tempfile
    return tempfile.gettempdir()


def screenshot_size(path):
    import Quartz
    url = Quartz.CFURLCreateFromFileSystemRepresentation(
        None, path.encode(), len(path.encode()), False
    )
    src = Quartz.CGImageSourceCreateWithURL(url, None)
    if src is None:
        return (0, 0)
    props = Quartz.CGImageSourceCopyPropertiesAtIndex(src, 0, None)
    w = props.get("PixelWidth", 0) or 0
    h = props.get("PixelHeight", 0) or 0
    return (w, h)


@action("mouse.move")
def mouse_move(x, y):
    import pyautogui
    pyautogui.moveTo(x, y, duration=0.15)
    return {"x": x, "y": y}


@action("mouse.click")
def mouse_click(x, y, button="left"):
    import pyautogui
    pyautogui.click(x, y, button=button)
    return {"x": x, "y": y, "button": button}


@action("mouse.scroll")
def mouse_scroll(delta_y, x=None, y=None):
    import pyautogui
    pyautogui.scroll(int(delta_y), x=x, y=y)
    return {"delta_y": delta_y}


@action("keyboard.type")
def keyboard_type(text):
    import pyautogui
    pyautogui.write(text)
    return {"typed": len(text)}


@action("keyboard.press")
def keyboard_press(key):
    import pyautogui
    pyautogui.press(_map_key(key))
    return {"pressed": key}


@action("keyboard.hotkey")
def keyboard_hotkey(keys):
    import pyautogui
    pyautogui.hotkey(*[_map_key(k) for k in keys])
    return {"hotkey": keys}


@action("apps.open")
def apps_open(id_or_path=None, file_path=None):
    """Open an app (bundle id or name) or a file with its default app."""
    if file_path:
        subprocess.run(["open", str(Path(file_path).expanduser())], check=True)
        return {"opened": file_path, "via": "default-app"}
    if id_or_path:
        p = Path(id_or_path).expanduser()
        if p.exists():
            subprocess.run(["open", str(p)], check=True)
            return {"opened": id_or_path, "via": "path"}
        # Try bundle id first, then app name.
        rc, _ = osascript(f'launch application id "{id_or_path}"', timeout=30)
        via = "bundle-id" if rc == 0 else "app-name"
        if rc != 0:
            rc2, out = osascript(f'launch application "{id_or_path}"', timeout=30)
            if rc2 != 0:
                raise ValueError(f"Could not launch app: {id_or_path} ({out})")
        return {"opened": id_or_path, "via": via}
    raise ValueError("apps.open needs id_or_path or file_path")


@action("files.reveal")
def files_reveal(path):
    p = Path(path).expanduser()
    if not p.exists():
        raise FileNotFoundError(f"No such path: {p}")
    subprocess.run(["open", "-R", str(p)], check=True)
    return {"revealed": str(p)}


@action("files.open")
def files_open(path):
    p = Path(path).expanduser()
    if not p.exists():
        raise FileNotFoundError(f"No such path: {p}")
    subprocess.run(["open", str(p)], check=True)
    return {"opened": str(p)}


@action("clipboard.read")
def clipboard_read():
    rc, out = osascript("the clipboard as text", timeout=10)
    if rc != 0:
        return {"text": ""}
    return {"text": out}


@action("clipboard.write")
def clipboard_write(text):
    subprocess.run(["pbcopy"], input=str(text).encode("utf-8"), check=True)
    return {"written": len(str(text))}


# ---------------------------------------------------------------------------
# Runtime: dispatch with permission gate
# ---------------------------------------------------------------------------

class Runtime:
    def __init__(self, grants: GrantStore, allow_origins):
        self.grants = grants
        self.allow_origins = set(allow_origins or [])

    def _granted(self, origin):
        return self.grants.get(origin)["capabilities"]

    async def dispatch(self, origin, msg_id, method, params):
        if method not in CAPABILITIES:
            return error(msg_id, -32601, f"Unknown method: {method}")

        # --- unrestricted bookkeeping ---------------------------------------
        if method == "runtime.status":
            return result(msg_id, runtime_status())
        if method == "permissions.query":
            return result(msg_id, self.grants.get(origin))
        if method == "permissions.revoke":
            return result(msg_id, self.grants.revoke(origin))

        if method == "permissions.request":
            requested = set((params or {}).get("permissions", []))
            unknown = requested - set(CAPABILITIES)
            if unknown:
                return error(msg_id, -32602, f"Unknown capabilities: {sorted(unknown)}")
            strong = [c for c in requested if CAPABILITIES[c][1]]
            # Strong capabilities always surface a native dialog.
            if strong and not await asyncio.to_thread(native_confirm, origin, strong):
                log.info("User DENIED %s for %s", strong, origin)
                return error(msg_id, -32002, "Permission denied by user")
            granted = sorted(set(self._granted(origin)) | requested)
            self.grants.set(origin, granted)
            return result(msg_id, self.grants.get(origin))

        # --- gated capabilities ----------------------------------------------
        granted = self._granted(origin)
        if method not in granted:
            return error(
                msg_id, -32000,
                f"Permission denied: {method} not granted for origin {origin}",
            )

        # Accessibility-sensitive actions: preflight check with helpful error.
        if CAPABILITIES[method][1] and method != "screen.capture":
            trusted = accessibility_trusted()
            if trusted is False:
                return error(
                    msg_id, -32001,
                    "OS permission missing: enable Accessibility for this "
                    "Runtime (System Settings > Privacy & Security > "
                    "Accessibility) then restart the Runtime.",
                )
        if method == "screen.capture":
            trusted = accessibility_trusted()
            if trusted is False:
                log.warning(
                    "Screen capture may return empty until Screen Recording "
                    "is granted; continuing."
                )

        fn = _ACTIONS.get(method)
        if fn is None:
            return error(msg_id, -32601, f"No implementation for {method}")

        # Validate params against the handler signature before running.
        sig = inspect.signature(fn)
        allowed = {p for p in sig.parameters}
        bad = set((params or {})) - allowed
        if bad:
            return error(msg_id, -32602, f"Unknown params for {method}: {sorted(bad)}")
        kwargs = {k: v for k, v in (params or {}).items() if k in allowed}

        try:
            if asyncio.iscoroutinefunction(fn):
                value = await fn(**kwargs)
            else:
                value = await asyncio.to_thread(fn, **kwargs)
        except Exception as exc:  # surface OS errors as JSON-RPC errors
            log.exception("Capability %s failed", method)
            return error(msg_id, -32000, f"{method} failed: {exc}")
        return result(msg_id, value)


def result(msg_id, value):
    return {"jsonrpc": "2.0", "id": msg_id, "result": value}


def error(msg_id, code, message):
    return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}}


# ---------------------------------------------------------------------------
# WebSocket endpoint
# ---------------------------------------------------------------------------

async def ws_handler(request):
    origin = request.headers.get("Origin", "")
    runtime: Runtime = request.app["runtime"]

    # Origin policy: reject disallowed origins. Empty allow list = allow all
    # (localhost development).
    if runtime.allow_origins and origin not in runtime.allow_origins:
        log.warning("Rejecting origin %s", origin)
        return web.Response(status=403, text="origin not allowed")

    ws = web.WebSocketResponse(max_msg_size=64 * 1024 * 1024)
    await ws.prepare(request)
    log.info("WS connected from origin=%s", origin or "<no Origin (curl)>")

    try:
        async for msg in ws:
            if msg.type != aiohttp.WSMsgType.TEXT:
                continue
            try:
                req = json.loads(msg.data)
            except json.JSONDecodeError:
                await ws.send_json(error(None, -32700, "Parse error"))
                continue
            if not isinstance(req, dict) or req.get("jsonrpc") != "2.0":
                await ws.send_json(error(None, -32600, "Invalid Request"))
                continue
            try:
                resp = await runtime.dispatch(
                    origin, req.get("id"), req.get("method"), req.get("params") or {}
                )
            except Exception as exc:
                log.exception("Dispatch crashed")
                resp = error(req.get("id"), -32603, f"Internal error: {exc}")
            resp.setdefault("id", req.get("id"))
            try:
                await ws.send_json(resp)
            except (ConnectionError, ConnectionResetError, BrokenPipeError):
                log.info("Client disconnected mid-response")
                break
    finally:
        log.info("WS disconnected")
    return ws


def build_app(runtime: Runtime):
    app = web.Application()
    app["runtime"] = runtime
    app.router.add_get("/ws", ws_handler)
    app.router.add_get("/health", lambda r: web.json_response({"ok": True}))
    return app


def main():
    ap = argparse.ArgumentParser(description="Computer.js macOS Runtime (M1)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--allow", action="append", default=[],
                    help="Allowed Origin header. Repeatable. Empty = allow all.")
    ap.add_argument("--grant-db", default=str(Path(__file__).with_name("grants.db")))
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )

    grants = GrantStore(args.grant_db)
    runtime = Runtime(grants, args.allow)
    app = build_app(runtime)

    log.info("Computer.js Runtime listening on ws://%s:%s/ws", args.host, args.port)
    log.info("Allowed origins: %s", args.allow or "ANY (local dev)")
    log.info("Grant DB: %s", args.grant_db)
    web.run_app(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()