import Foundation
import Network

// MARK: - Tiny static HTTP server for the control panel

final class HTTPServer {
    private let port: UInt16
    private let rootDir: URL
    private var listener: NWListener?
    private let fileManager = FileManager.default

    init(port: UInt16, rootDir: URL) {
        self.port = port
        self.rootDir = rootDir
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            Logger.log("HTTP listener failed: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener?.stateUpdateHandler = { state in
            if case .ready = state {
                Logger.log("Control panel ready on http://127.0.0.1:\(self.port)/")
            } else if case .failed(let error) = state {
                Logger.log("HTTP server failed: \(error)")
            }
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        readRequest(connection: connection, buffer: Data())
    }

    private func readRequest(connection: NWConnection, buffer: Data) {
        var current = buffer
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                current.append(data)
            }
            if let headerEnd = current.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: current[..<headerEnd.lowerBound], as: UTF8.self)
                self.respond(connection, header: header)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.readRequest(connection: connection, buffer: current)
            }
        }
    }

    private func respond(_ connection: NWConnection, header: String) {
        let lines = header.split(separator: "\r\n")
        guard let requestLine = lines.first else {
            sendStatus(connection, code: 400, text: "Bad Request")
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendStatus(connection, code: 405, text: "Method Not Allowed")
            return
        }
        var path = String(parts[1])
        if path == "/" { path = "/index.html" }
        // Prevent path traversal
        let cleaned = path.split(separator: "/").map(String.init)
        let url = cleaned.reduce(rootDir) { $0.appendingPathComponent($1) }

        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            sendStatus(connection, code: 404, text: "Not Found")
            return
        }

        let contentType = Self.contentType(for: url.pathExtension)
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendStatus(_ connection: NWConnection, code: Int, text: String) {
        let body = "<html><body><h1>\(code) \(text)</h1></body></html>"
        let response = "HTTP/1.1 \(code) \(text)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}