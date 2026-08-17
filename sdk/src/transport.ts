/**
 * JSON-RPC 2.0 transport over a single WebSocket.
 * One persistent connection, incrementing request ids, promise per request.
 */

import { ComputerError, ErrorCodes } from "./types";

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (reason: ComputerError) => void;
}

export interface TransportOptions {
  /** WebSocket URL of the Computer Runtime, e.g. "ws://127.0.0.1:8787/ws". */
  url: string;
  /** Reconnect automatically when the socket drops. Default true. */
  reconnect?: boolean;
  /** Called with the current connection state. */
  onStatusChange?: (connected: boolean) => void;
}

export class RpcTransport {
  private readonly url: string;
  private readonly reconnect: boolean;
  private readonly onStatusChange?: (connected: boolean) => void;

  private ws: WebSocket | null = null;
  private nextId = 1;
  private pending = new Map<number, PendingRequest>();
  private closedByUser = false;
  private reconnectTimer: number | null = null;

  constructor(options: TransportOptions) {
    this.url = options.url;
    this.reconnect = options.reconnect ?? true;
    this.onStatusChange = options.onStatusChange;
  }

  /** Open the WebSocket if it is not already connected. */
  async connect(): Promise<void> {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return;
    this.closedByUser = false;
    await this.openSocket();
  }

  private openSocket(): Promise<void> {
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
      ws.onmessage = (event: MessageEvent<string>) => {
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
        // onclose always follows; reject the connect promise so callers notice.
        if (!settled) {
          settled = true;
          reject(new ComputerError(ErrorCodes.InternalError, "WebSocket error"));
        }
      };
    });
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer !== null) return;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      void this.openSocket().catch(() => {
        /* reconnect loop continues via onclose */
      });
    }, 1000);
  }

  /** JSON-RPC call. Resolves with the `result`, rejects with ComputerError. */
  call(method: string, params?: object): Promise<unknown> {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return Promise.reject(new ComputerError(ErrorCodes.InternalError, "Not connected"));
    }
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws!.send(
        JSON.stringify({
          jsonrpc: "2.0",
          id,
          method,
          params: params ?? {},
        }),
      );
    });
  }

  private handleMessage(raw: string): void {
    let msg: { id?: unknown; result?: unknown; error?: { code?: number; message?: string } };
    try {
      msg = JSON.parse(raw) as typeof msg;
    } catch {
      return; // ignore malformed frames
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

  private rejectAll(error: ComputerError): void {
    for (const [, pending] of this.pending) pending.reject(error);
    this.pending.clear();
  }

  /** Close the connection permanently (no reconnect). */
  close(): void {
    this.closedByUser = true;
    if (this.reconnectTimer !== null) {
      window.clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws?.close();
  }
}