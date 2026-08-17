#!/usr/bin/env python3
"""Automated smoke test for the Computer.js runtime (both live and in-process)."""
import asyncio
import json
import sys
import tempfile
from pathlib import Path

import aiohttp

ORIGIN = "http://localhost:3000"
WS_URL = "ws://127.0.0.1:8787/ws"


async def rpc(ws, method, params=None, msg_id=1):
    await ws.send_json({"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params or {}})
    return await ws.receive_json()


async def live_tests():
    print("=== Test A: live server over WebSocket ===")
    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(WS_URL, headers={"Origin": ORIGIN}, max_msg_size=64 * 1024 * 1024) as ws:
            # 1. status
            r = await rpc(ws, "runtime.status")
            assert r["result"]["status"] == "running", r
            print("[ok] runtime.status ->", r["result"]["os"], r["result"]["version"])

            # 2. fresh grant state
            r = await rpc(ws, "permissions.query")
            assert r["result"]["capabilities"] == [], r
            print("[ok] permissions.query starts empty")

            # 3. gated action before grant must be denied
            r = await rpc(ws, "screen.capture")
            assert r["error"]["code"] == -32000, r
            print("[ok] screen.capture denied before grant:", r["error"]["message"])

            # 4. unknown method
            r = await rpc(ws, "totally.bogus")
            assert r["error"]["code"] == -32601, r
            print("[ok] unknown method rejected")

            # 5. request only non-strong capabilities -> granted without dialog
            r = await rpc(ws, "permissions.request", {"permissions": ["files.reveal", "clipboard.write"]})
            assert set(r["result"]["capabilities"]) == {"files.reveal", "clipboard.write"}, r
            print("[ok] weak permissions granted:", r["result"]["capabilities"])

            # 6. clipboard.write -> real OS write through pbcopy
            r = await rpc(ws, "clipboard.write", {"text": "computerjs-smoke-test"})
            assert r["result"]["written"] == 21, r
            print("[ok] clipboard.write ->", r["result"])

            # 7. clipboard.read is strong & not granted -> denied
            r = await rpc(ws, "clipboard.read")
            assert r["error"]["code"] == -32000, r
            print("[ok] clipboard.read still denied:", r["error"]["message"])

            # 8. files.reveal on a real temp file -> Finder shows it
            tmp = Path(tempfile.gettempdir()) / "computerjs-smoke.txt"
            tmp.write_text("hello")
            r = await rpc(ws, "files.reveal", {"path": str(tmp)})
            assert r["result"]["revealed"] == str(tmp), r
            print("[ok] files.reveal ->", r["result"])

            # 9. invalid params are rejected deterministically
            r = await rpc(ws, "clipboard.write", {"nonsense": True})
            assert r["error"]["code"] == -32602, r
            print("[ok] unknown param rejected:", r["error"]["message"])

            # 10. revoke works
            r = await rpc(ws, "permissions.revoke")
            assert r["result"]["capabilities"] == [], r
            print("[ok] revoke ->", r["result"])
    print("=== Test A PASSED ===\n")


async def in_process_tests():
    print("=== Test B: strong-capability path (approval auto-simulated) ===")
    sys.path.insert(0, str(Path(__file__).parent))
    import runtime as rt

    # Replace the native dialog with an auto-approve only inside this test.
    rt.native_confirm = lambda origin, caps: True

    grants = rt.GrantStore(":memory:")
    runtime = rt.Runtime(grants, [ORIGIN])
    app = rt.build_app(runtime)

    runner = aiohttp.web.AppRunner(app)
    await runner.setup()
    site = aiohttp.web.TCPSite(runner, "127.0.0.1", 8799)
    await site.start()
    try:
        ws_url = "ws://127.0.0.1:8799/ws"
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(ws_url, headers={"Origin": ORIGIN}, max_msg_size=64 * 1024 * 1024) as ws:
                # grant strong capabilities (dialog auto-approved in test)
                r = await rpc(ws, "permissions.request", {"permissions": ["screen.capture", "mouse.move", "keyboard.type"]})
                assert set(r["result"]["capabilities"]) >= {"screen.capture", "mouse.move", "keyboard.type"}, r
                print("[ok] strong permissions granted:", r["result"]["capabilities"])

                # mouse.move -> returns position
                r = await rpc(ws, "mouse.move", {"x": 100, "y": 100})
                assert r["result"]["x"] == 100 and r["result"]["y"] == 100, r
                print("[ok] mouse.move ->", r["result"])

                # keyboard.type -> returns count
                r = await rpc(ws, "keyboard.type", {"text": "hi"})
                assert r["result"]["typed"] == 2, r
                print("[ok] keyboard.type ->", r["result"])

                # screen.capture -> returns a PNG payload
                r = await rpc(ws, "screen.capture", {"target": "screen"})
                assert r["result"]["format"] == "png" and r["result"]["data"], r
                import base64, io
                img = base64.b64decode(r["result"]["data"])
                assert len(img) > 1000, "screenshot suspiciously small"
                print(f"[ok] screen.capture -> {r['result']['width']}x{r['result']['height']} {len(img)//1024} KiB png")
    finally:
        await runner.cleanup()
    print("=== Test B PASSED ===")


if __name__ == "__main__":
    asyncio.run(live_tests())
    asyncio.run(in_process_tests())