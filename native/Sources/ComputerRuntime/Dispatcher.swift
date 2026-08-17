import Foundation
import Network
import AppKit

// MARK: - JSON-RPC dispatcher with permission gate

final class Dispatcher {
    private let store = PermissionStore.shared

    private func sendResponse(_ payload: Data, to connection: NWConnection) {
        // Server -> client frames are unmasked. Fin + text opcode.
        var header = Data()
        let len = payload.count
        header.append(0x81)
        if len < 126 {
            header.append(UInt8(len))
        } else if len < 65536 {
            header.append(126)
            header.append(UInt8((len >> 8) & 0xFF))
            header.append(UInt8(len & 0xFF))
        } else {
            header.append(127)
            var big = UInt64(len).bigEndian
            withUnsafeBytes(of: &big) { header.append(contentsOf: $0) }
        }
        var frame = header
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func send(_ object: [String: Any], to connection: NWConnection) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            sendResponse(data, to: connection)
        } catch {
            Logger.log("Failed to serialize response: \(error)")
        }
    }

    func result(_ id: Int, _ value: [String: Any], _ connection: NWConnection) {
        send(["jsonrpc": "2.0", "id": id, "result": value], to: connection)
    }

    func error(_ id: Int, _ code: Int, _ message: String, _ connection: NWConnection) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]], to: connection)
    }

    func dispatch(raw: Data, origin: String, connection: NWConnection) {
        var object: [String: Any]
        do {
            object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
        } catch {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]], to: connection)
            return
        }
        guard let method = object["method"] as? String else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]], to: connection)
            return
        }
        let id = object["id"] as? Int ?? -1
        let params = object["params"] as? [String: Any] ?? [:]

        guard let info = CAPABILITIES[method] else {
            error(id, -32601, "Unknown method: \(method)", connection)
            return
        }

        // Unrestricted methods
        switch method {
        case "runtime.status":
            result(id, [
                "server": "computer-runtime",
                "version": "0.2.0-native",
                "os": "macos",
                "status": "running",
                "transport": "local-ws",
            ], connection)
            return
        case "permissions.query":
            result(id, store.query(origin: origin), connection)
            return
        case "permissions.revoke":
            result(id, store.revoke(origin: origin), connection)
            return
        case "permissions.request":
            handlePermissionRequest(id: id, params: params, origin: origin, connection: connection)
            return
        default:
            break
        }

        // Gated methods: must be granted first
        let granted = Set(store.query(origin: origin)["capabilities"] as? [String] ?? [])
        guard granted.contains(method) else {
            error(id, -32000, "Permission denied: \(method) not granted for origin \(origin.isEmpty ? "(unknown)" : origin)", connection)
            return
        }

        // OS permission preflight: if missing, prompt the user with a native
        // one-click alert that opens the exact System Settings pane. A plain
        // "Allow" cannot self-grant these system permissions — only the user
        // can toggle them — so this gives them a one-click path to do it.
        if info.needsAccessibility && !OSChecks.accessibilityTrusted() {
            OSChecks.promptOSPermission(
                kind: "accessibility", origin: origin, capability: method, connection: connection,
                onDone: { [weak self] in self?.retryOrDeny(id: id, method: method, params: params, connection: connection, kind: "Accessibility") }
            )
            return
        }
        if info.needsScreenRecording && !OSChecks.screenRecordingGranted() {
            OSChecks.promptOSPermission(
                kind: "screen", origin: origin, capability: method, connection: connection,
                onDone: { [weak self] in self?.retryOrDeny(id: id, method: method, params: params, connection: connection, kind: "Screen Recording") }
            )
            return
        }

        runCapability(id: id, method: method, params: params, connection: connection)
    }

    /// After the user opens Settings and returns, re-check; run if granted,
    /// otherwise return a friendly OS-permission error.
    private func retryOrDeny(id: Int, method: String, params: [String: Any], connection: NWConnection, kind: String) {
        let cap = CAPABILITIES[method]
        if cap?.needsAccessibility == true, !OSChecks.accessibilityTrusted() {
            error(id, -32001, "\(kind) not granted — enable it in System Settings, then retry.", connection)
            return
        }
        if cap?.needsScreenRecording == true, !OSChecks.screenRecordingGranted() {
            error(id, -32001, "\(kind) not granted — enable it in System Settings, then retry.", connection)
            return
        }
        runCapability(id: id, method: method, params: params, connection: connection)
    }

    private func runCapability(id: Int, method: String, params: [String: Any], connection: NWConnection) {
        do {
            let value = try Capabilities.call(method: method, params: params)
            result(id, value, connection)
        } catch let error as RPCError {
            if case .code(let code, let message) = error {
                self.error(id, code, message, connection)
            }
        } catch {
            self.error(id, -32000, "\(method) failed: \(error.localizedDescription)", connection)
        }
    }

    private func handlePermissionRequest(id: Int, params: [String: Any], origin: String, connection: NWConnection) {
        let requested = Set(params["permissions"] as? [String] ?? [])
        let known = Set(CAPABILITIES.keys)
        let unknown = requested.subtracting(known)
        guard unknown.isEmpty else {
            error(id, -32602, "Unknown capabilities: \(unknown.sorted().joined(separator: ", "))", connection)
            return
        }
        let strong = requested.filter { CAPABILITIES[$0]!.strong }
        if !strong.isEmpty && !OSChecks.userApproves(origin: origin, capabilities: Array(strong)) {
            error(id, -32002, "Permission denied by user", connection)
            return
        }
        let merged = granted(origin) + requested
        _ = store.grant(origin: origin, capabilities: Array(Set(merged)))
        result(id, store.query(origin: origin), connection)
    }

    private func granted(_ origin: String) -> [String] {
        return store.query(origin: origin)["capabilities"] as? [String] ?? []
    }
}

// MARK: - Native permission checks + approval dialog

enum OSChecks {
    /// True when Accessibility is granted. Passing `kAXTrustedCheckOptionPrompt: true`
    /// makes macOS show its own one-click "grant Accessibility" prompt the first
    /// time — the user taps Allow in that popup, no Settings hunting.
    static func accessibilityTrusted() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    static func screenRecordingGranted() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    /// Shows a NATIVE alert: "Computer.js needs {kind} to use {capability}."
    /// Tapping "Allow" opens the exact System Settings pane so the user just
    /// flicks the switch — far easier than hunting for it. Called on the main
    /// thread; `onDone` runs once the user has interacted.
    static func promptOSPermission(kind: String, origin: String, capability: String, connection: NWConnection, onDone: @escaping () -> Void) {
        DispatchQueue.main.async {
            let setting = kind == "screen"
                ? "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                : "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Computer.js needs \(kind)"
            alert.informativeText =
                "\(kind == "screen" ? "Screen Recording" : "Accessibility") is required to \n"
                + "use ‘\(capability)’ for \(origin.isEmpty ? "this website" : origin).\n\n"
                + "Tap Allow to open System Settings, then turn it on — it takes a second."
            alert.addButton(withTitle: "Allow & Open Settings")
            alert.addButton(withTitle: "Not now")
            let choice = alert.runModal()
            if choice == .alertFirstButtonReturn {
                if let url = URL(string: setting) {
                    NSWorkspace.shared.open(url)
                }
            }
            onDone()
        }
    }

    /// Runs a NATIVE macOS approval dialog on the main thread. Returns true on Allow.
    static func userApproves(origin: String, capabilities: [String]) -> Bool {
        let autoApprove = ProcessInfo.processInfo.environment["COMPUTER_RUNTIME_AUTO_APPROVE"] == "1"
        if autoApprove { return true }

        var approved = false
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            defer { semaphore.signal() }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Computer.js permission request"
            let capText = capabilities.map { "• \($0)" }.joined(separator: "\n")
            let originText = origin.isEmpty ? "a website" : origin
            alert.informativeText = "\(originText) wants to use these computer capabilities:\n\n\(capText)\n\nAllow this site to control your Mac?"
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            approved = alert.runModal() == .alertFirstButtonReturn
        }
        semaphore.wait()
        return approved
    }
}