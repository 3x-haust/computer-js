import AppKit
import Foundation

// MARK: - App entry point

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: RuntimeServer!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status bar item so the user always sees the runtime is running.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "Computer.js Runtime")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Control Panel", action: #selector(openPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Permissions…", action: #selector(showPermissions), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Computer.js Runtime", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        runtime = RuntimeServer()
        runtime.start()
    }

    @objc private func openPanel() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:8788/")!)
    }

    @objc private func showPermissions() {
        let grants = runtime.showGrants()
        let alert = NSAlert()
        alert.messageText = "Computer.js permissions"
        alert.informativeText = grants.isEmpty
            ? "No website has been granted permissions yet."
            : grants.map { "\($0.origin)\n  \($0.capabilities.joined(separator: ", "))" }.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        runtime.stop()
        NSApp.terminate(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar app, no dock icon
app.run()