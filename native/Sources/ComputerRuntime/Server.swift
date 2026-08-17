import AppKit
import Foundation
import Network

// MARK: - JSON-RPC types

struct RPCRequest: Codable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: [String: JSONValue]?
}

enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown JSON value"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var raw: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let arr): return arr.map { $0.raw }
        case .object(let dict): return dict.mapValues { $0.raw }
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var intValue: Int? { if case .int(let i) = self { return i } else { return nil } }
    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
}

enum RPCError: Error {
    case code(Int, String)
}

// MARK: - Capability catalog

struct CapabilityInfo {
    let risk: String        // "low" | "med" | "high"
    let strong: Bool        // requires native approval dialog
    let needsAccessibility: Bool
    let needsScreenRecording: Bool
}

let CAPABILITIES: [String: CapabilityInfo] = [
    "runtime.status": .init(risk: "low", strong: false, needsAccessibility: false, needsScreenRecording: false),
    "system.info": .init(risk: "low", strong: false, needsAccessibility: false, needsScreenRecording: false),
    "system.control": .init(risk: "med", strong: true, needsAccessibility: false, needsScreenRecording: false),
    "permissions.query": .init(risk: "low", strong: false, needsAccessibility: false, needsScreenRecording: false),
    "permissions.request": .init(risk: "low", strong: false, needsAccessibility: false, needsScreenRecording: false),
    "permissions.revoke": .init(risk: "low", strong: false, needsAccessibility: false, needsScreenRecording: false),
    "screen.capture": .init(risk: "med", strong: true, needsAccessibility: false, needsScreenRecording: true),
    "mouse.move": .init(risk: "high", strong: true, needsAccessibility: true, needsScreenRecording: false),
    "mouse.click": .init(risk: "high", strong: true, needsAccessibility: true, needsScreenRecording: false),
    "mouse.scroll": .init(risk: "high", strong: true, needsAccessibility: true, needsScreenRecording: false),
    "keyboard.type": .init(risk: "high", strong: true, needsAccessibility: true, needsScreenRecording: false),
    "keyboard.press": .init(risk: "high", strong: true, needsAccessibility: true, needsScreenRecording: false),
    "keyboard.hotkey": .init(risk: "high", strong: true, needsAccessibility: true, needsScreenRecording: false),
    "apps.open": .init(risk: "low", strong: false, needsAccessibility: false, needsScreenRecording: false),
    "files.reveal": .init(risk: "low", strong: false, needsAccessibility: false, needsScreenRecording: false),
    "files.open": .init(risk: "low", strong: false, needsAccessibility: false, needsScreenRecording: false),
    "clipboard.read": .init(risk: "med", strong: true, needsAccessibility: false, needsScreenRecording: false),
    "clipboard.write": .init(risk: "med", strong: false, needsAccessibility: false, needsScreenRecording: false),
]

// MARK: - Runtime server orchestration

final class RuntimeServer {
    private var wsServer: WebSocketServer?
    private var httpServer: HTTPServer?

    func start() {
        // WebSocket JSON-RPC on 8787
        wsServer = WebSocketServer(port: 8787, dispatcher: Dispatcher())
        wsServer?.start()

        // Static control panel on 8788
        httpServer = HTTPServer(port: 8788, rootDir: Self.wwwDir)
        httpServer?.start()

        let about = "Computer.js Runtime v0.2.0 (native)"
        Logger.log(about)
        Logger.log("  WebSocket: ws://127.0.0.1:8787/ws")
        Logger.log("  Control panel: http://127.0.0.1:8788/  (opening browser…)")
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:8788/")!)
    }

    func stop() {
        wsServer?.stop()
        httpServer?.stop()
    }

    func showGrants() -> [(origin: String, capabilities: [String])] {
        let store = PermissionStore.shared
        return store.all()
    }

    static var wwwDir: URL {
        // Bundled app: Contents/Resources/www ; dev: repo root/web
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("www")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        // Dev fallback: look for web/ near the current working directory or above
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var dir = here.appendingPathComponent("web")
        if FileManager.default.fileExists(atPath: dir.path) { return dir }
        dir = here.deletingLastPathComponent().appendingPathComponent("web")
        if FileManager.default.fileExists(atPath: dir.path) { return dir }
        dir = here.appendingPathComponent("../web")
        if FileManager.default.fileExists(atPath: dir.path) { return dir.standardizedFileURL }
        return URL(fileURLWithPath: "/tmp")
    }
}

// MARK: - Tiny logger

enum Logger {
    private static let lock = NSLock()
    static func log(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        NSLog("[ComputerRuntime] %@", message)
    }
}