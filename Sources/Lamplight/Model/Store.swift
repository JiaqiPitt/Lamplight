import Foundation

/// Keeps every sheet as one JSON file on this Mac. Nothing leaves the machine.
///   ~/Library/Application Support/Lamplight/Entries/
final class Store {
    let directory: URL
    private(set) var entries: [UUID: Entry] = [:]
    private var files: [UUID: URL] = [:]
    private let writer = DispatchQueue(label: "lamplight.store.writer", qos: .utility)

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let override = ProcessInfo.processInfo.environment["LAMPLIGHT_DATA_DIR"], !override.isEmpty {
            // For trying the app out without touching the real sheets.
            self.directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory = base.appendingPathComponent("Lamplight/Entries", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = Store.decoder()
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), var entry = try? decoder.decode(Entry.self, from: data) else {
                NSLog("Lamplight: could not read \(url.lastPathComponent)")
                continue
            }
            entry = Store.withoutLiftedInk(entry)
            entries[entry.id] = entry
            files[entry.id] = url
        }
    }

    private func fileName(for e: Entry) -> String {
        let date = e.kind == .diary && !e.day.isEmpty ? e.day : Entry.dayKey(e.createdAt)
        return "\(e.kind.rawValue)-\(date)-\(e.id.uuidString.prefix(8)).json"
    }

    /// Characters removed with the correction tape leave nothing behind once their trace has faded.
    static func withoutLiftedInk(_ entry: Entry) -> Entry {
        var e = entry
        for r in e.rows.indices where e.rows[r].contains(where: { $0.d == 2 }) {
            e.rows[r].removeAll { $0.d == 2 }
        }
        return e
    }

    /// Saves a sheet. With `wait`, returns only once the file is on disk (used when quitting).
    func save(_ live: Entry, wait: Bool = false) {
        let entry = Store.withoutLiftedInk(live)
        entries[entry.id] = entry
        let url = files[entry.id] ?? directory.appendingPathComponent(fileName(for: entry))
        files[entry.id] = url
        guard let data = try? Store.encoder().encode(entry) else { return }
        let work = {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("Lamplight: could not save \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if wait { writer.sync(execute: work) } else { writer.async(execute: work) }
    }

    /// Moves a sheet's file to the Trash, where it can still be recovered.
    func delete(_ id: UUID) {
        entries[id] = nil
        guard let url = files.removeValue(forKey: id) else { return }
        writer.async {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func isSaved(_ id: UUID) -> Bool { files[id] != nil }

    func diary(day: String) -> Entry? {
        entries.values.first { $0.kind == .diary && $0.day == day }
    }

    func list(_ kind: EntryKind) -> [Entry] {
        entries.values.filter { $0.kind == kind }.sorted { a, b in
            if kind == .diary { return a.day > b.day }
            return a.createdAt > b.createdAt
        }
    }
}
