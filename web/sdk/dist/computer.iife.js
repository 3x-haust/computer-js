"use strict";
(() => {
  // src/types.ts
  var ComputerError = class extends Error {
    code;
    constructor(code, message) {
      super(message);
      this.name = "ComputerError";
      this.code = code;
    }
  };
  var ErrorCodes = {
    ParseError: -32700,
    InvalidRequest: -32600,
    MethodNotFound: -32601,
    InvalidParams: -32602,
    InternalError: -32603,
    PermissionDenied: -32e3,
    OSPermissionMissing: -32001,
    UserDenied: -32002
  };

  // src/transport.ts
  var RpcTransport = class {
    url;
    reconnect;
    onStatusChange;
    ws = null;
    nextId = 1;
    pending = /* @__PURE__ */ new Map();
    closedByUser = false;
    reconnectTimer = null;
    constructor(options) {
      this.url = options.url;
      this.reconnect = options.reconnect ?? true;
      this.onStatusChange = options.onStatusChange;
    }
    /** Open the WebSocket if it is not already connected. */
    async connect() {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) return;
      this.closedByUser = false;
      await this.openSocket();
    }
    openSocket() {
      return new Promise((resolve, reject) => {
        let settled = false;
        const ws = new WebSocket(this.url);
        this.ws = ws;
        ws.onopen = () => {
          if (!settled) {
            settled = true;
            resolve();
          }
          this.onStatusChange?.(true);
        };
        ws.onmessage = (event) => {
          this.handleMessage(event.data);
        };
        ws.onclose = () => {
          this.onStatusChange?.(false);
          if (this.ws === ws) this.ws = null;
          this.rejectAll(new ComputerError(ErrorCodes.InternalError, "Connection closed"));
          if (!settled) {
            settled = true;
            reject(new ComputerError(ErrorCodes.InternalError, "Connection closed before open"));
          }
          if (!this.closedByUser && this.reconnect) this.scheduleReconnect();
        };
        ws.onerror = () => {
          if (!settled) {
            settled = true;
            reject(new ComputerError(ErrorCodes.InternalError, "WebSocket error"));
          }
        };
      });
    }
    scheduleReconnect() {
      if (this.reconnectTimer !== null) return;
      this.reconnectTimer = window.setTimeout(() => {
        this.reconnectTimer = null;
        void this.openSocket().catch(() => {
        });
      }, 1e3);
    }
    /** JSON-RPC call. Resolves with the `result`, rejects with ComputerError. */
    call(method, params) {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
        return Promise.reject(new ComputerError(ErrorCodes.InternalError, "Not connected"));
      }
      const id = this.nextId++;
      return new Promise((resolve, reject) => {
        this.pending.set(id, { resolve, reject });
        this.ws.send(
          JSON.stringify({
            jsonrpc: "2.0",
            id,
            method,
            params: params ?? {}
          })
        );
      });
    }
    handleMessage(raw) {
      let msg;
      try {
        msg = JSON.parse(raw);
      } catch {
        return;
      }
      if (typeof msg.id !== "number") return;
      const pending = this.pending.get(msg.id);
      if (!pending) return;
      this.pending.delete(msg.id);
      if (msg.error) {
        pending.reject(new ComputerError(msg.error.code ?? -1, msg.error.message ?? "RPC error"));
      } else {
        pending.resolve(msg.result);
      }
    }
    rejectAll(error) {
      for (const [, pending] of this.pending) pending.reject(error);
      this.pending.clear();
    }
    /** Close the connection permanently (no reconnect). */
    close() {
      this.closedByUser = true;
      if (this.reconnectTimer !== null) {
        window.clearTimeout(this.reconnectTimer);
        this.reconnectTimer = null;
      }
      this.ws?.close();
    }
  };

  // src/index.ts
  var DEFAULT_URL = "ws://127.0.0.1:8787/ws";
  var ComputerClient = class {
    transport = null;
    url = DEFAULT_URL;
    connected = false;
    /** True while a live WebSocket to the Runtime is open. */
    get isConnected() {
      return this.connected;
    }
    /** Connect to the Runtime and confirm it is alive. */
    async connect(options = {}) {
      this.url = options.url ?? DEFAULT_URL;
      this.transport = new RpcTransport({
        url: this.url,
        reconnect: options.reconnect ?? true,
        onStatusChange: (up) => {
          this.connected = up;
          options.onStatusChange?.(up);
        }
      });
      await this.transport.connect();
      const status = await this.callTyped("runtime.status");
      return status;
    }
    /** Close the connection permanently (no auto-reconnect). */
    disconnect() {
      this.transport?.close();
      this.transport = null;
      this.connected = false;
    }
    /** Read the current Runtime status. Throws if the Runtime is not reachable. */
    status() {
      return this.callTyped("runtime.status");
    }
    // ---------------------------------------------------------------------
    // Internal: typed JSON-RPC call
    // ---------------------------------------------------------------------
    async callTyped(method, params) {
      const transport = this.requireTransport();
      const result = await transport.call(method, params);
      return result;
    }
    requireTransport() {
      if (!this.transport) {
        throw new ComputerError(
          ErrorCodes.InternalError,
          "Not connected. Call computer.connect() first."
        );
      }
      return this.transport;
    }
    // ---------------------------------------------------------------------
    // System
    // ---------------------------------------------------------------------
    system = {
      /** Live system diagnostics (model, OS, memory, uptime). */
      info: () => this.callTyped("system.info"),
      /** Esc actions: lock the screen or sleep the display. */
      control: (params) => this.callTyped("system.control", params)
    };
    // ---------------------------------------------------------------------
    // Permissions (grant gates every capability)
    // ---------------------------------------------------------------------
    permissions = {
      /** List the capabilities currently granted to this origin. */
      query: () => this.callTyped("permissions.query"),
      /**
       * Ask the user to grant capabilities. Strong capabilities
       * (mouse, keyboard, screen) always show the Runtime's native
       * approval dialog before being granted.
       */
      request: (caps) => this.callTyped("permissions.request", { permissions: caps }),
      /** Remove all capabilities granted to this origin. */
      revoke: () => this.callTyped("permissions.revoke")
    };
    // ---------------------------------------------------------------------
    // Screen
    // ---------------------------------------------------------------------
    screen = {
      /** Capture the full screen or the frontmost window as a PNG. */
      capture: (params = {}) => this.callTyped("screen.capture", params)
    };
    // ---------------------------------------------------------------------
    // Mouse
    // ---------------------------------------------------------------------
    mouse = {
      move: (params) => this.callTyped("mouse.move", params),
      click: (params) => this.callTyped("mouse.click", params),
      scroll: (params) => this.callTyped("mouse.scroll", {
        delta_y: params.delta_y,
        x: params.x ?? null,
        y: params.y ?? null
      })
    };
    // ---------------------------------------------------------------------
    // Keyboard
    // ---------------------------------------------------------------------
    keyboard = {
      /** Type visible text. Prefer this for normal strings. */
      type: (params) => this.callTyped("keyboard.type", params),
      /** Press a single named key (e.g. "ENTER", "ESC", "ARROW_DOWN"). */
      press: (params) => this.callTyped("keyboard.press", params),
      /** Press modifier+key combos, e.g. ["META", "S"]. */
      hotkey: (params) => this.callTyped("keyboard.hotkey", params)
    };
    // ---------------------------------------------------------------------
    // Apps
    // ---------------------------------------------------------------------
    apps = {
      /** Open an app (bundle id or name) or a file with its default app. */
      open: (params) => this.callTyped("apps.open", params)
    };
    // ---------------------------------------------------------------------
    // Files
    // ---------------------------------------------------------------------
    files = {
      /** Reveal a file or folder in Finder. */
      reveal: (params) => this.callTyped("files.reveal", params),
      /** Open a file or folder with its default app. */
      open: (params) => this.callTyped("files.open", params)
    };
    // ---------------------------------------------------------------------
    // Clipboard
    // ---------------------------------------------------------------------
    clipboard = {
      read: () => this.callTyped("clipboard.read"),
      write: (params) => this.callTyped("clipboard.write", params)
    };
  };
  var computer = new ComputerClient();

  // src/browser.ts
  window.computer = computer;
})();
