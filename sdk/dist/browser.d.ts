/**
 * Browser entry point: exposes the Computer.js SDK as a global `computer`
 * object so a plain <script> tag can call `computer.screen.capture()` etc.
 * Bundled by esbuild from index.ts; this file only wires the global.
 */
import { computer } from "./index";
declare global {
    interface Window {
        computer: typeof computer;
    }
}
