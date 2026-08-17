/**
 * JSON-RPC 2.0 transport over a single WebSocket.
 * One persistent connection, incrementing request ids, promise per request.
 */
export interface TransportOptions {
    /** WebSocket URL of the Computer Runtime, e.g. "ws://127.0.0.1:8787/ws". */
    url: string;
    /** Reconnect automatically when the socket drops. Default true. */
    reconnect?: boolean;
    /** Called with the current connection state. */
    onStatusChange?: (connected: boolean) => void;
}
export declare class RpcTransport {
    private readonly url;
    private readonly reconnect;
    private readonly onStatusChange?;
    private ws;
    private nextId;
    private pending;
    private closedByUser;
    private reconnectTimer;
    constructor(options: TransportOptions);
    /** Open the WebSocket if it is not already connected. */
    connect(): Promise<void>;
    private openSocket;
    private scheduleReconnect;
    /** JSON-RPC call. Resolves with the `result`, rejects with ComputerError. */
    call(method: string, params?: object): Promise<unknown>;
    private handleMessage;
    private rejectAll;
    /** Close the connection permanently (no reconnect). */
    close(): void;
}
