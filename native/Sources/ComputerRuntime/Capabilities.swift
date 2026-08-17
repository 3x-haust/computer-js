import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - Native capability implementations

enum Capabilities {
    /// Calls the native implementation for a method. Throws RPCError on failure.
    static func call(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "runtime.status": return runtimeStatus()
        case "system.info": return systemInfo()
        case "system.control": return try systemControl(params)
        case "screen.capture": return try captureScreen(params)
        case "mouse.move": return try mouseMove(params)
        case "mouse.click": return try mouseClick(params)
        case "mouse.scroll": return try mouseScroll(params)
        case "keyboard.type": return try keyboardType(params)
        case "keyboard.press": return try keyboardPress(params)
        case "keyboard.hotkey": return try keyboardHotkey(params)
        case "apps.open": return try appsOpen(params)
        case "files.reveal": return try filesReveal(params)
        case "files.open": return try filesOpen(params)
        case "clipboard.read": return clipboardRead()
        case "clipboard.write": return try clipboardWrite(params)
        default:
            throw RPCError.code(-32601, "No implementation for \(method)")
        }
    }

    // MARK: Runtime & System

    private static func runtimeStatus() -> [String: Any] {
        return [
            "server": "computer-runtime",
            "version": RuntimeVersion.string,
            "os": "macos",
            "status": "running",
            "transport": "local-ws",
        ]
    }

    /// Useful system diagnostics shown in the control panel.
    private static func systemInfo() -> [String: Any] {
        let env = ProcessInfo.processInfo
        let mem = env.physicalMemory
        // Model name
        let model = systemCommand("/usr/sbin/sysctl -n hw.model") ?? "Mac"
        let chip = env.operatingSystemVersionString
        // Uptime
        let uptime = env.systemUptime
        let days = Int(uptime) / 86400
        let hours = (Int(uptime) % 86400) / 3600
        let mins = (Int(uptime) % 3600) / 60
        let host = Host.current().localizedName ?? ""
        return [
            "model": model,
            "host": host,
            "chip": env.processorCount > 16 ? "high-core-count" : "\(env.processorCount)-core",
            "osVersion": chip,
            "architecture": systemCommand("/usr/bin/uname -m") ?? "unknown",
            "memoryGB": Double(mem) / 1_073_741_824.0,
            "processorCount": env.processorCount,
            "uptime": "\(days)d \(hours)h \(mins)m",
        ]
    }

    /// Lock the screen or sleep the display — useful ESC actions.
    private static func systemControl(_ params: [String: Any]) throws -> [String: Any] {
        let action = params["action"] as? String ?? "lock"
        switch action {
        case "lock":
            // Turn off the display. On an account that requires a password on
            // wake, this routes through the lock screen (unlock with password /
            // Touch ID / Face ID). Prefer any CGSession binary where present;
            // otherwise fall back to display sleep. Never posts to a made-up URL
            // scheme (that produced error -50).
            let cgsession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
            if FileManager.default.fileExists(atPath: cgsession) {
                _ = systemCommand("\"\(cgsession)\" -suspend")
            } else {
                _ = systemCommand("pmset displaysleepnow")
            }
            return ["action": "lock", "ok": true]
        case "sleep":
            // Put the display to sleep.
            _ = systemCommand("pmset displaysleepnow")
            return ["action": "sleep", "ok": true]
        default:
            throw RPCError.code(-32602, "Unknown system.control action: \(action) (lock|sleep)")
        }
    }

    private static func systemCommand(_ command: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func captureScreen(_ params: [String: Any]) throws -> [String: Any] {
        let target = params["target"] as? String ?? "screen"
        let semaphore = DispatchSemaphore(value: 0)
        var resultImage: CGImage?
        var captureError: Error?

        let worker = DispatchQueue(label: "capture.worker")

        worker.async {
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    let config = SCStreamConfiguration()
                    config.width = content.displays.first?.width ?? 1
                    config.height = content.displays.first?.height ?? 1
                    config.showsCursor = true

                    var filter: SCContentFilter
                    if target == "window", let window = frontWindow(in: content) {
                        filter = SCContentFilter(desktopIndependentWindow: window)
                    } else if let display = content.displays.first {
                        filter = SCContentFilter(display: display, excludingWindows: [])
                    } else {
                        captureError = RPCError.code(-32000, "No display available for capture")
                        semaphore.signal()
                        return
                    }
                    let image: CGImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    resultImage = image
                } catch {
                    captureError = error
                }
                semaphore.signal()
            }
        }

        semaphore.wait()

        if let captureError {
            let message = "Could not capture screen: \(captureError.localizedDescription) (check Screen Recording permission)"
            throw RPCError.code(-32001, message)
        }
        guard let image = resultImage else {
            throw RPCError.code(-32001, "Could not capture screen (check Screen Recording permission)")
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw RPCError.code(-32000, "Could not encode PNG")
        }
        return [
            "width": image.width,
            "height": image.height,
            "format": "png",
            "data": pngData.base64EncodedString(),
        ]
    }

    private static func frontWindow(in content: SCShareableContent) -> SCWindow? {
        return content.windows
            .filter { $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.applicationName != "Window Server" }
            .sorted { $0.windowID < $1.windowID }
            .last
    }

    // MARK: Mouse

    private static func mouseMove(_ params: [String: Any]) throws -> [String: Any] {
        let x = try double(params, "x")
        let y = try double(params, "y")
        let point = CGPoint(x: x, y: y)
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
        return ["x": x, "y": y]
    }

    private static func mouseClick(_ params: [String: Any]) throws -> [String: Any] {
        let x = try double(params, "x")
        let y = try double(params, "y")
        let buttonName = params["button"] as? String ?? "left"
        let button: CGMouseButton = buttonName == "right" ? .right : (buttonName == "middle" ? .center : .left)
        let point = CGPoint(x: x, y: y)
        let typeDown: CGEventType = button == .right ? .rightMouseDown : (button == .center ? .otherMouseDown : .leftMouseDown)
        let typeUp: CGEventType = button == .right ? .rightMouseUp : (button == .center ? .otherMouseUp : .leftMouseUp)
        CGEvent(mouseEventSource: nil, mouseType: typeDown, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        usleep(50_000)
        CGEvent(mouseEventSource: nil, mouseType: typeUp, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        return ["x": x, "y": y, "button": buttonName]
    }

    private static func mouseScroll(_ params: [String: Any]) throws -> [String: Any] {
        let delta = try int(params, "delta_y")
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0)
        event?.post(tap: .cghidEventTap)
        return ["delta_y": delta]
    }

    // MARK: Keyboard

    private static func keyboardType(_ params: [String: Any]) throws -> [String: Any] {
        let text = try string(params, "text")
        typeText(text)
        return ["typed": text.utf16.count]
    }

    private static func keyboardPress(_ params: [String: Any]) throws -> [String: Any] {
        let key = try string(params, "key")
        guard let code = keyCode(for: key) else {
            throw RPCError.code(-32602, "Unknown key: \(key)")
        }
        pressKey(code)
        return ["pressed": key]
    }

    private static func keyboardHotkey(_ params: [String: Any]) throws -> [String: Any] {
        let keys = try stringArray(params, "keys")
        let mapped = keys.compactMap { keyCode(for: $0) }
        guard mapped.count == keys.count, let lastCode = mapped.last else {
            throw RPCError.code(-32602, "Unknown key in hotkey: \(keys)")
        }
        pressKey(lastCode, flags: flags(for: keys))
        return ["hotkey": keys]
    }

    private static func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            var chars = Array(String(scalar).utf16)
            if chars.isEmpty { chars = [0] }
            let count = chars.count
            chars.withUnsafeMutableBufferPointer { buffer in
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                    down.keyboardSetUnicodeString(stringLength: count, unicodeString: buffer.baseAddress!)
                    down.post(tap: .cghidEventTap)
                }
                if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    up.keyboardSetUnicodeString(stringLength: count, unicodeString: buffer.baseAddress!)
                    up.post(tap: .cghidEventTap)
                }
            }
            usleep(10_000)
        }
    }

    private static func pressKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(30_000)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.flags = flags
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        let upper = key.uppercased()
        let map: [String: CGKeyCode] = [
            "RETURN": 36, "ENTER": 36, "TAB": 48, "SPACE": 49, "DELETE": 51, "BACKSPACE": 51,
            "ESC": 53, "ESCAPE": 53, "ARROW_RIGHT": 124, "ARROW_LEFT": 123, "ARROW_DOWN": 125,
            "ARROW_UP": 126, "META": 55, "CMD": 55, "COMMAND": 55, "SHIFT": 56,
            "CTRL": 59, "CONTROL": 59, "ALT": 58, "OPTION": 58,
            "HOME": 115, "END": 119, "PAGE_UP": 116, "PAGE_DOWN": 121,
            "=": 24, "-": 27, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50, "[": 33, "]": 30,
        ]
        if let code = map[upper] { return code }
        if upper.count == 1 {
            if let ascii = upper.unicodeScalars.first?.value {
                if ascii >= 65, ascii <= 90 { return CGKeyCode(ascii - 65) }
                if ascii >= 48, ascii <= 57 {
                    let digits: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
                    return digits[Int(ascii - 48)]
                }
            }
        }
        return nil
    }

    private static func flags(for keys: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for key in keys.map({ $0.uppercased() }) {
            switch key {
            case "META", "CMD", "COMMAND": flags.insert(.maskCommand)
            case "SHIFT": flags.insert(.maskShift)
            case "CTRL", "CONTROL": flags.insert(.maskControl)
            case "ALT", "OPTION": flags.insert(.maskAlternate)
            default: break
            }
        }
        return flags
    }

    // MARK: Apps

    private static func appsOpen(_ params: [String: Any]) throws -> [String: Any] {
        if let filePath = params["file_path"] as? String {
            let url = URL(fileURLWithPath: NSString(string: filePath).expandingTildeInPath)
            let ok = NSWorkspace.shared.open(url)
            guard ok else { throw RPCError.code(-32000, "Could not open file: \(filePath)") }
            return ["opened": filePath, "via": "default-app"]
        }
        if let idOrPath = params["id_or_path"] as? String {
            let url = URL(fileURLWithPath: NSString(string: idOrPath).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) {
                let ok = NSWorkspace.shared.open(url)
                guard ok else { throw RPCError.code(-32000, "Could not open path: \(idOrPath)") }
                return ["opened": idOrPath, "via": "path"]
            }
            // Bundle id
            if NSWorkspace.shared.launchApplication(withBundleIdentifier: idOrPath, options: [], additionalEventParamDescriptor: nil, launchIdentifier: nil) {
                return ["opened": idOrPath, "via": "bundle-id"]
            }
            // App name (search existing apps)
            let apps = NSWorkspace.shared.runningApplications
            if let app = apps.first(where: { $0.localizedName?.lowercased() == idOrPath.lowercased() }),
               let bundleURL = app.bundleURL {
                let sem = DispatchSemaphore(value: 0)
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in sem.signal() }
                sem.wait()
                return ["opened": idOrPath, "via": "name"]
            }
            throw RPCError.code(-32000, "Could not launch app: \(idOrPath) (try a bundle id like com.apple.Safari)")
        }
        throw RPCError.code(-32602, "apps.open needs id_or_path or file_path")
    }

    // MARK: Files

    private static func filesReveal(_ params: [String: Any]) throws -> [String: Any] {
        let path = try string(params, "path")
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RPCError.code(-32000, "No such path: \(path)")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return ["revealed": url.path]
    }

    private static func filesOpen(_ params: [String: Any]) throws -> [String: Any] {
        let path = try string(params, "path")
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RPCError.code(-32000, "No such path: \(path)")
        }
        guard NSWorkspace.shared.open(url) else {
            throw RPCError.code(-32000, "Could not open path: \(path)")
        }
        return ["opened": url.path]
    }

    // MARK: Clipboard

    private static func clipboardRead() -> [String: Any] {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        return ["text": text]
    }

    private static func clipboardWrite(_ params: [String: Any]) throws -> [String: Any] {
        let text = try string(params, "text")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return ["written": text.utf16.count]
    }

    // MARK: Param helpers

    private static func double(_ params: [String: Any], _ key: String) throws -> Double {
        guard let v = params[key] as? Double ?? (params[key] as? NSNumber)?.doubleValue else {
            throw RPCError.code(-32602, "Missing or invalid number param: \(key)")
        }
        return v
    }

    private static func int(_ params: [String: Any], _ key: String) throws -> Int {
        guard let v = params[key] as? Int ?? (params[key] as? NSNumber)?.intValue else {
            throw RPCError.code(-32602, "Missing or invalid int param: \(key)")
        }
        return v
    }

    private static func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let v = params[key] as? String else {
            throw RPCError.code(-32602, "Missing or invalid string param: \(key)")
        }
        return v
    }

    private static func stringArray(_ params: [String: Any], _ key: String) throws -> [String] {
        guard let v = params[key] as? [String] else {
            throw RPCError.code(-32602, "Missing or invalid string array param: \(key)")
        }
        return v
    }
}