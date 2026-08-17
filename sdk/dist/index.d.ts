/**
 * Computer.js Web SDK — call real computer capabilities from a webpage.
 *
 * Usage (browser module):
 *   import { computer } from "@computerjs/sdk";
 *   await computer.connect({ url: "ws://127.0.0.1:8787/ws" });
 *   await computer.permissions.request(["screen.capture", "mouse.move"]);
 *   const shot = await computer.screen.capture();
 */
import type { AppsOpenParams, Capability, ClipboardReadResult, ClipboardWriteResult, FileResult, GrantState, KeyboardHotkeyParams, KeyboardTypeParams, MouseClickParams, MouseMoveParams, MouseScrollParams, RuntimeStatusResult, ScreenshotResult } from "./types";
export * from "./types";
export declare const VERSION = "0.1.0-milestone1";
export declare const DEFAULT_URL = "ws://127.0.0.1:8787/ws";
export interface ConnectOptions {
    /** Runtime WebSocket URL. Defaults to ws://127.0.0.1:8787/ws. */
    url?: string;
    /** Reconnect automatically when the socket drops. Default true. */
    reconnect?: boolean;
    /** Called with the current connection state. */
    onStatusChange?: (connected: boolean) => void;
}
/** The Computer.js client. Create one with the singleton `computer` or `createComputer()`. */
export declare class ComputerClient {
    private transport;
    private url;
    private connected;
    /** True while a live WebSocket to the Runtime is open. */
    get isConnected(): boolean;
    /** Connect to the Runtime and confirm it is alive. */
    connect(options?: ConnectOptions): Promise<RuntimeStatusResult>;
    /** Close the connection permanently (no auto-reconnect). */
    disconnect(): void;
    /** Read the current Runtime status. Throws if the Runtime is not reachable. */
    status(): Promise<RuntimeStatusResult>;
    private callTyped;
    private requireTransport;
    readonly permissions: {
        /** List the capabilities currently granted to this origin. */
        query: () => Promise<GrantState>;
        /**
         * Ask the user to grant capabilities. Strong capabilities
         * (mouse, keyboard, screen) always show the Runtime's native
         * approval dialog before being granted.
         */
        request: (caps: Capability[]) => Promise<GrantState>;
        /** Remove all capabilities granted to this origin. */
        revoke: () => Promise<GrantState>;
    };
    readonly screen: {
        /** Capture the full screen or the frontmost window as a PNG. */
        capture: (params?: {
            target?: "screen" | "window";
        }) => Promise<ScreenshotResult>;
    };
    readonly mouse: {
        move: (params: MouseMoveParams) => Promise<MouseMoveParams>;
        click: (params: MouseClickParams) => Promise<MouseClickParams>;
        scroll: (params: MouseScrollParams) => Promise<{
            delta_y: number;
        }>;
    };
    readonly keyboard: {
        /** Type visible text. Prefer this for normal strings. */
        type: (params: KeyboardTypeParams) => Promise<{
            typed: number;
        }>;
        /** Press a single named key (e.g. "ENTER", "ESC", "ARROW_DOWN"). */
        press: (params: {
            key: string;
        }) => Promise<{
            pressed: string;
        }>;
        /** Press modifier+key combos, e.g. ["META", "S"]. */
        hotkey: (params: KeyboardHotkeyParams) => Promise<{
            hotkey: string[];
        }>;
    };
    readonly apps: {
        /** Open an app (bundle id or name) or a file with its default app. */
        open: (params: AppsOpenParams) => Promise<FileResult & {
            via?: string;
        }>;
    };
    readonly files: {
        /** Reveal a file or folder in Finder. */
        reveal: (params: {
            path: string;
        }) => Promise<FileResult>;
        /** Open a file or folder with its default app. */
        open: (params: {
            path: string;
        }) => Promise<FileResult>;
    };
    readonly clipboard: {
        read: () => Promise<ClipboardReadResult>;
        write: (params: {
            text: string;
        }) => Promise<ClipboardWriteResult>;
    };
}
/** Create an independent Computer.js client. */
export declare function createComputer(): ComputerClient;
/** Shared singleton — this is the `computer` from the product spec. */
export declare const computer: ComputerClient;
