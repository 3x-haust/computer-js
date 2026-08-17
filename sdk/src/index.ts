/**
 * Computer.js Web SDK — call real computer capabilities from a webpage.
 *
 * Usage (browser module):
 *   import { computer } from "@computerjs/sdk";
 *   await computer.connect({ url: "ws://127.0.0.1:8787/ws" });
 *   await computer.permissions.request(["screen.capture", "mouse.move"]);
 *   const shot = await computer.screen.capture();
 */

import { RpcTransport } from "./transport";
import { ComputerError, ErrorCodes } from "./types";
import type {
  AppsOpenParams,
  Capability,
  ClipboardReadResult,
  ClipboardWriteResult,
  FileResult,
  GrantState,
  KeyboardHotkeyParams,
  KeyboardTypeParams,
  MouseClickParams,
  MouseMoveParams,
  MouseScrollParams,
  RuntimeStatusResult,
  ScreenshotResult,
  SystemInfo,
} from "./types";

export * from "./types";

export const VERSION = "0.1.0-milestone1";
export const DEFAULT_URL = "ws://127.0.0.1:8787/ws";

export interface ConnectOptions {
  /** Runtime WebSocket URL. Defaults to ws://127.0.0.1:8787/ws. */
  url?: string;
  /** Reconnect automatically when the socket drops. Default true. */
  reconnect?: boolean;
  /** Called with the current connection state. */
  onStatusChange?: (connected: boolean) => void;
}

/** The Computer.js client. Create one with the singleton `computer` or `createComputer()`. */
export class ComputerClient {
  private transport: RpcTransport | null = null;
  private url = DEFAULT_URL;
  private connected = false;

  /** True while a live WebSocket to the Runtime is open. */
  get isConnected(): boolean {
    return this.connected;
  }

  /** Connect to the Runtime and confirm it is alive. */
  async connect(options: ConnectOptions = {}): Promise<RuntimeStatusResult> {
    this.url = options.url ?? DEFAULT_URL;
    this.transport = new RpcTransport({
      url: this.url,
      reconnect: options.reconnect ?? true,
      onStatusChange: (up) => {
        this.connected = up;
        options.onStatusChange?.(up);
      },
    });
    await this.transport.connect();
    const status = await this.callTyped<RuntimeStatusResult>("runtime.status");
    return status;
  }

  /** Close the connection permanently (no auto-reconnect). */
  disconnect(): void {
    this.transport?.close();
    this.transport = null;
    this.connected = false;
  }

  /** Read the current Runtime status. Throws if the Runtime is not reachable. */
  status(): Promise<RuntimeStatusResult> {
    return this.callTyped<RuntimeStatusResult>("runtime.status");
  }

  // ---------------------------------------------------------------------
  // Internal: typed JSON-RPC call
  // ---------------------------------------------------------------------

  private async callTyped<T>(method: string, params?: object): Promise<T> {
    const transport = this.requireTransport();
    const result = await transport.call(method, params);
    return result as T;
  }

  private requireTransport(): RpcTransport {
    if (!this.transport) {
      throw new ComputerError(
        ErrorCodes.InternalError,
        "Not connected. Call computer.connect() first.",
      );
    }
    return this.transport;
  }

  // ---------------------------------------------------------------------
  // System
  // ---------------------------------------------------------------------

  readonly system = {
    /** Live system diagnostics (model, OS, memory, uptime). */
    info: (): Promise<SystemInfo> =>
      this.callTyped<SystemInfo>("system.info"),

    /** Esc actions: lock the screen or sleep the display. */
    control: (params: { action: "lock" | "sleep" }): Promise<{ action: string; ok: boolean }> =>
      this.callTyped<{ action: string; ok: boolean }>("system.control", params),
  };

  // ---------------------------------------------------------------------
  // Permissions (grant gates every capability)
  // ---------------------------------------------------------------------

  readonly permissions = {
    /** List the capabilities currently granted to this origin. */
    query: (): Promise<GrantState> =>
      this.callTyped<GrantState>("permissions.query"),

    /**
     * Ask the user to grant capabilities. Strong capabilities
     * (mouse, keyboard, screen) always show the Runtime's native
     * approval dialog before being granted.
     */
    request: (caps: Capability[]): Promise<GrantState> =>
      this.callTyped<GrantState>("permissions.request", { permissions: caps }),

    /** Remove all capabilities granted to this origin. */
    revoke: (): Promise<GrantState> =>
      this.callTyped<GrantState>("permissions.revoke"),
  };

  // ---------------------------------------------------------------------
  // Screen
  // ---------------------------------------------------------------------

  readonly screen = {
    /** Capture the full screen or the frontmost window as a PNG. */
    capture: (params: { target?: "screen" | "window" } = {}): Promise<ScreenshotResult> =>
      this.callTyped<ScreenshotResult>("screen.capture", params),
  };

  // ---------------------------------------------------------------------
  // Mouse
  // ---------------------------------------------------------------------

  readonly mouse = {
    move: (params: MouseMoveParams): Promise<MouseMoveParams> =>
      this.callTyped<MouseMoveParams>("mouse.move", params),

    click: (params: MouseClickParams): Promise<MouseClickParams> =>
      this.callTyped<MouseClickParams>("mouse.click", params),

    scroll: (params: MouseScrollParams): Promise<{ delta_y: number }> =>
      this.callTyped<{ delta_y: number }>("mouse.scroll", {
        delta_y: params.delta_y,
        x: params.x ?? null,
        y: params.y ?? null,
      }),
  };

  // ---------------------------------------------------------------------
  // Keyboard
  // ---------------------------------------------------------------------

  readonly keyboard = {
    /** Type visible text. Prefer this for normal strings. */
    type: (params: KeyboardTypeParams): Promise<{ typed: number }> =>
      this.callTyped<{ typed: number }>("keyboard.type", params),

    /** Press a single named key (e.g. "ENTER", "ESC", "ARROW_DOWN"). */
    press: (params: { key: string }): Promise<{ pressed: string }> =>
      this.callTyped<{ pressed: string }>("keyboard.press", params),

    /** Press modifier+key combos, e.g. ["META", "S"]. */
    hotkey: (params: KeyboardHotkeyParams): Promise<{ hotkey: string[] }> =>
      this.callTyped<{ hotkey: string[] }>("keyboard.hotkey", params),
  };

  // ---------------------------------------------------------------------
  // Apps
  // ---------------------------------------------------------------------

  readonly apps = {
    /** Open an app (bundle id or name) or a file with its default app. */
    open: (params: AppsOpenParams): Promise<FileResult & { via?: string }> =>
      this.callTyped<FileResult & { via?: string }>("apps.open", params),
  };

  // ---------------------------------------------------------------------
  // Files
  // ---------------------------------------------------------------------

  readonly files = {
    /** Reveal a file or folder in Finder. */
    reveal: (params: { path: string }): Promise<FileResult> =>
      this.callTyped<FileResult>("files.reveal", params),

    /** Open a file or folder with its default app. */
    open: (params: { path: string }): Promise<FileResult> =>
      this.callTyped<FileResult>("files.open", params),
  };

  // ---------------------------------------------------------------------
  // Clipboard
  // ---------------------------------------------------------------------

  readonly clipboard = {
    read: (): Promise<ClipboardReadResult> =>
      this.callTyped<ClipboardReadResult>("clipboard.read"),

    write: (params: { text: string }): Promise<ClipboardWriteResult> =>
      this.callTyped<ClipboardWriteResult>("clipboard.write", params),
  };
}

/** Create an independent Computer.js client. */
export function createComputer(): ComputerClient {
  return new ComputerClient();
}

/** Shared singleton — this is the `computer` from the product spec. */
export const computer = new ComputerClient();