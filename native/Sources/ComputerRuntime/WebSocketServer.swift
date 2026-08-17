import Foundation
import Network

// MARK: - WebSocket server (Network.framework)

final class WebSocketServer {
    private let port: UInt16
    private let dispatcher: Dispatcher
    private var listener: NWListener?

    init(port: UInt16, dispatcher: Dispatcher) {
        self.port = port
        self.dispatcher = dispatcher
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            Logger.log("WebSocket listener failed to start: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.accept(connection)
        }
        listener?.stateUpdateHandler = { state in
            if case .ready = state {
                Logger.log("WebSocket server ready on ws://127.0.0.1:\(self.port)/ws")
            } else if case .failed(let error) = state {
                Logger.log("WebSocket server failed: \(error)")
            }
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        // Handshake is auto-handled by Network.framework for ws:// upgrade
        // connections accepted by a TCP listener? No — Network.framework's
        // WebSocket support is connection-level (client side). For a server we
        // must implement the HTTP Upgrade handshake ourselves. We accept TCP,
        // read the HTTP request, respond 101, then speak WebSocket frames.
        handleHTTPUpgrade(connection: connection)
    }

    /// Reads the initial HTTP request; if it's a WebSocket upgrade, replies 101
    /// and starts the JSON-RPC frame loop. Otherwise 404/400.
    private func handleHTTPUpgrade(connection: NWConnection) {
        var requestData = Data()
        var gotHeaders = false
        var origin = ""

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                requestData.append(data)
            }
            if let headerRange = Self.findHeaderEnd(in: requestData), !gotHeaders {
                gotHeaders = true
                let headerText = String(decoding: requestData.prefix(headerRange.lowerBound), as: UTF8.self)
                origin = Self.headerValue(headerText, name: "origin") ?? ""
                let path = Self.requestPath(headerText) ?? "/"
                let isUpgrade = headerText.lowercased().contains("upgrade: websocket")
                if isUpgrade {
                    self.respondUpgrade(connection: connection, requestText: headerText) {
                        self.runFrameLoop(connection: connection, origin: origin, leftover: requestData[headerRange.upperBound...])
                    }
                } else {
                    let body = "WebSocket endpoint. Use ws://127.0.0.1:\(self.port)/ws"
                    let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(resp.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
        }
    }

    private func respondUpgrade(connection: NWConnection, requestText: String, completion: @escaping () -> Void) {
        let key = Self.headerValue(requestText, name: "sec-websocket-key") ?? ""
        let accept = Self.webSocketAccept(key: key)
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
            completion()
        })
    }

    private func runFrameLoop(connection: NWConnection, origin: String, leftover: Data) {
        var buffer = leftover
        func readMore() {
            connection.receive(minimumIncompleteLength: 2, maximumLength: 64 * 1024 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty { buffer.append(data) }

                // Process complete frames from the buffer
                var frameProcessed = false
                while true {
                    guard let frame = Self.parseFrame(buffer: buffer) else { break }
                    Logger.log("FRAME opcode=\(frame.opcode) payload=\(frame.payload.count)B")
                    buffer.removeFirst(frame.consumed)
                    frameProcessed = true
                    switch frame.opcode {
                    case 0x1, 0x2: // text / binary
                        self.dispatcher.dispatch(raw: frame.payload, origin: origin, connection: connection)
                    case 0x8: // close
                        connection.send(content: Data([0x88, 0x00]), completion: .contentProcessed { _ in connection.cancel() })
                        return
                    case 0x9: // ping -> pong
                        connection.send(content: Data([0x8A, UInt8(frame.payload.count)]) + frame.payload, completion: .contentProcessed { _ in })
                    default:
                        break
                    }
                }

                if isComplete || (error != nil) {
                    connection.cancel()
                } else if !frameProcessed && buffer.count > 64 * 1024 * 1024 {
                    Logger.log("WebSocket buffer overflow, closing connection")
                    connection.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    // MARK: - Frame parsing (RFC 6455)

    private struct Frame {
        let opcode: UInt8
        let payload: Data
        let consumed: Int
    }

    private static func parseFrame(buffer: Data) -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[buffer.startIndex]
        let b1 = buffer[buffer.startIndex + 1]
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var payloadLen = UInt64(b1 & 0x7F)
        var offset = 2
        if payloadLen == 126 {
            guard buffer.count >= 4 else { return nil }
            payloadLen = UInt64(buffer[buffer.startIndex + 2]) << 8 | UInt64(buffer[buffer.startIndex + 3])
            offset = 4
        } else if payloadLen == 127 {
            guard buffer.count >= 10 else { return nil }
            var big: UInt64 = 0
            for i in 0..<8 {
                big = big << 8 | UInt64(buffer[buffer.startIndex + 2 + i])
            }
            payloadLen = big
            offset = 10
        }
        var maskKey: Data?
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = buffer.subdata(in: (buffer.startIndex + offset)..<(buffer.startIndex + offset + 4))
            offset += 4
        }
        guard payloadLen <= 64 * 1024 * 1024 else { return nil }
        guard buffer.count >= offset + Int(payloadLen) else { return nil }
        var payload = Data(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + Int(payloadLen))])
        if let maskKey {
            var keyBytes = [UInt8](maskKey)
            for i in 0..<payload.count {
                payload[i] = payload[payload.startIndex + i] ^ keyBytes[i % 4]
            }
        }
        return Frame(opcode: opcode, payload: payload, consumed: offset + Int(payloadLen))
    }

    // MARK: - HTTP helpers

    private static func findHeaderEnd(in data: Data) -> Range<Data.Index>? {
        return data.range(of: Data("\r\n\r\n".utf8))
    }

    private static func requestPath(_ header: String) -> String? {
        let lines = header.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    private static func headerValue(_ header: String, name: String) -> String? {
        for line in header.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix(name.lowercased() + ":") {
                return String(line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func webSocketAccept(key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let hashed = sha1(magic)
        return hashed.base64EncodedString()
    }

    private static func sha1(_ string: String) -> Data {
        var ctx = SHA1Context()
        SHA1Init(&ctx)
        SHA1Update(&ctx, string)
        var digest = SHA1Digest()
        SHA1Final(&digest, &ctx)
        return Data(digest.bytes)
    }
}

// Minimal SHA-1 (public domain-style implementation)
struct SHA1Context {
    var state = [UInt32](repeating: 0, count: 5)
    var buffer = [UInt8](repeating: 0, count: 64)
    var bufferLen = 0
    var totalLen: UInt64 = 0
}

struct SHA1Digest {
    var bytes = [UInt8](repeating: 0, count: 20)
}

func SHA1Init(_ ctx: inout SHA1Context) {
    ctx.state = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    ctx.bufferLen = 0
    ctx.totalLen = 0
}

func SHA1Update(_ ctx: inout SHA1Context, _ string: String) {
    let bytes = Array(string.utf8)
    var i = 0
    while i < bytes.count {
        ctx.buffer[ctx.bufferLen] = bytes[i]
        ctx.bufferLen += 1
        ctx.totalLen += 1
        if ctx.bufferLen == 64 {
            SHA1ProcessBlock(&ctx, block: Array(ctx.buffer))
            ctx.bufferLen = 0
        }
        i += 1
    }
}

func SHA1Final(_ digest: inout SHA1Digest, _ ctx: inout SHA1Context) {
    let bitLen = ctx.totalLen &* 8
    ctx.buffer[ctx.bufferLen] = 0x80
    ctx.bufferLen += 1
    while ctx.bufferLen != 56 {
        if ctx.bufferLen == 64 {
            SHA1ProcessBlock(&ctx, block: Array(ctx.buffer))
            ctx.bufferLen = 0
        }
        ctx.buffer[ctx.bufferLen] = 0
        ctx.bufferLen += 1
    }
    for i in 0..<8 {
        ctx.buffer[56 + i] = UInt8((bitLen >> (56 - i * 8)) & 0xFF)
    }
    SHA1ProcessBlock(&ctx, block: Array(ctx.buffer))
    var out = [UInt32](ctx.state)
    for i in 0..<5 { out[i] = out[i].bigEndian }
    out.withUnsafeBytes { raw in
        for i in 0..<20 { digest.bytes[i] = raw[i] }
    }
}

func SHA1ProcessBlock(_ ctx: inout SHA1Context, block: [UInt8]) {
    var w = [UInt32](repeating: 0, count: 80)
    for i in 0..<16 {
        w[i] = UInt32(block[i*4]) << 24 | UInt32(block[i*4+1]) << 16 | UInt32(block[i*4+2]) << 8 | UInt32(block[i*4+3])
    }
    for i in 16..<80 {
        w[i] = rotateLeft(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1)
    }
    var a = ctx.state[0], b = ctx.state[1], c = ctx.state[2], d = ctx.state[3], e = ctx.state[4]
    for i in 0..<80 {
        var f: UInt32, k: UInt32
        if i < 20 { f = (b & c) | (~b & d); k = 0x5A827999 }
        else if i < 40 { f = b ^ c ^ d; k = 0x6ED9EBA1 }
        else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC }
        else { f = b ^ c ^ d; k = 0xCA62C1D6 }
        let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[i]
        e = d; d = c; c = rotateLeft(b, 30); b = a; a = temp
    }
    ctx.state[0] &+= a; ctx.state[1] &+= b; ctx.state[2] &+= c; ctx.state[3] &+= d; ctx.state[4] &+= e
}

func rotateLeft(_ v: UInt32, _ n: UInt32) -> UInt32 {
    return (v << n) | (v >> (32 - n))
}