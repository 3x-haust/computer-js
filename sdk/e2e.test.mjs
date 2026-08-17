#!/usr/bin/env node
/**
 * SDK end-to-end test: loads the BUILT ESM bundle and drives it against
 * the live Python Runtime over a real WebSocket (Node's native WebSocket).
 */
import { computer } from "./dist/computer.js";

const failures = [];
function check(name, cond, detail) {
  if (cond) {
    console.log(`[ok] ${name}${detail ? ` -> ${detail}` : ""}`);
  } else {
    failures.push(name);
    console.log(`[FAIL] ${name}${detail ? ` -> ${detail}` : ""}`);
  }
}

// 1. status via the SDK facade
const status = await computer.connect({ url: "ws://127.0.0.1:8787/ws" });
check("connect+status", status.status === "running" && status.os === "macos", `${status.os} ${status.version}`);

// 2. permissions via the SDK
const before = await computer.permissions.query();
check("permissions.query", Array.isArray(before.capabilities), JSON.stringify(before));

// 3. screen.capture denied before grant (typed error path)
let denied = false;
try {
  await computer.screen.capture();
} catch (e) {
  denied = e.code === -32000;
  console.log(`[ok] screen.capture denied pre-grant: ${e.message}`);
}
check("pre-grant denial surface", denied);

// 4. weak grant then real action through the SDK
const grant = await computer.permissions.request(["clipboard.write", "files.reveal"]);
check("permissions.request", grant.capabilities.includes("clipboard.write"), JSON.stringify(grant.capabilities));

const written = await computer.clipboard.write({ text: "sdk-e2e" });
check("clipboard.write via SDK", written.written === 7, JSON.stringify(written));

// 5. strong cap still denied (no dialog in headless test)
let strongDenied = false;
try {
  await computer.clipboard.read();
} catch (e) {
  strongDenied = e.code === -32000;
}
check("clipboard.read still denied", strongDenied);

// 6. post-condition
const after = await computer.permissions.query();
check("grant persisted on server", after.capabilities.includes("files.reveal"), JSON.stringify(after.capabilities));

computer.disconnect();
console.log(failures.length === 0 ? "=== SDK E2E PASSED ===" : `=== ${failures.length} FAILURES ===`);
process.exit(failures.length === 0 ? 0 : 1);