/**
 * Shared types for the Computer.js SDK.
 * These mirror the JSON-RPC wire protocol implemented by the Runtime.
 */

/** Every capability the Runtime can grant. */
export type Capability =
  | "runtime.status"
  | "permissions.query"
  | "permissions.request"
  | "permissions.revoke"
  | "screen.capture"
  | "mouse.move"
  | "mouse.click"
  | "mouse.scroll"
  | "keyboard.type"
  | "keyboard.press"
  | "keyboard.hotkey"
  | "apps.open"
  | "files.reveal"
  | "files.open"
  | "clipboard.read"
  | "clipboard.write";

export interface RuntimeStatusResult {
  server: string;
  version: string;
  os: string;
  status: "running";
  transport: string;
}

export interface GrantState {
  origin: string;
  capabilities: Capability[];
}

export interface ScreenshotResult {
  /** Base64-encoded PNG bytes. */
  data: string;
  width: number;
  height: number;
  format: "png";
}

export interface AppsOpenParams {
  /** App bundle id (e.g. "com.apple.Safari") or app name, or a file/dir path. */
  id_or_path?: string;
  /** Open a file with its default app. */
  file_path?: string;
}

export interface FileResult {
  opened?: string;
  revealed?: string;
  via?: string;
}

export interface ClipboardWriteResult {
  written: number;
}

export interface ClipboardReadResult {
  text: string;
}

export interface MouseMoveParams {
  x: number;
  y: number;
}

export interface MouseClickParams {
  x: number;
  y: number;
  button?: "left" | "right" | "middle";
}

export interface MouseScrollParams {
  delta_y: number;
  x?: number | null;
  y?: number | null;
}

export interface KeyboardTypeParams {
  text: string;
}

export interface KeyboardHotkeyParams {
  keys: string[];
}

/** Error surfaced by the Runtime or transport. */
export class ComputerError extends Error {
  readonly code: number;

  constructor(code: number, message: string) {
    super(message);
    this.name = "ComputerError";
    this.code = code;
  }
}

/** Predefined JSON-RPC / runtime error codes. */
export const ErrorCodes = {
  ParseError: -32700,
  InvalidRequest: -32600,
  MethodNotFound: -32601,
  InvalidParams: -32602,
  InternalError: -32603,
  PermissionDenied: -32000,
  OSPermissionMissing: -32001,
  UserDenied: -32002,
} as const;