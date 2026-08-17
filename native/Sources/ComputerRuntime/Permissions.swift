import Foundation

// MARK: - Per-origin permission store

struct GrantRecord {
    let origin: String
    let capabilities: [String]
}

final class PermissionStore {
    static let shared = PermissionStore()

    private let lock = NSLock()
    private var records: [String: [String]] = [:]  // origin -> capabilities
    private let fileURL: URL

    init() {
        // Storage inside Application Support so grants survive restarts.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ComputerRuntime", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("grants.json")
        load()
    }

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else {
            return
        }
        records = obj
    }

    private func save() {
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func query(origin: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["origin": origin, "capabilities": records[origin] ?? []]
    }

    func grant(origin: String, capabilities: [String]) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let merged = Array(Set((records[origin] ?? []) + capabilities)).sorted()
        records[origin] = merged
        saveLocked()
        return ["origin": origin, "capabilities": merged]
    }

    func revoke(origin: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        records.removeValue(forKey: origin)
        saveLocked()
        return ["origin": origin, "capabilities": []]
    }

    private func saveLocked() {
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func all() -> [(origin: String, capabilities: [String])] {
        lock.lock(); defer { lock.unlock() }
        return records.map { (origin: $0.key, capabilities: $0.value) }.sorted { $0.origin < $1.origin }
    }
}