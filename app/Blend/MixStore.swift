import Foundation
import Observation

/// Presets on disk: one JSON file per mix in Application Support, written atomically with
/// the previous version kept as a .bak next to it.
@MainActor
@Observable
final class MixStore {
    private(set) var mixes: [Mix] = []
    private(set) var loadErrors: [String] = []
    @ObservationIgnored var onChange: (([Mix]) -> Void)?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Blend/Mixes", isDirectory: true)
        load()
    }

    func load() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []
        var loaded: [Mix] = []
        loadErrors = []
        for file in files where file.pathExtension == "json" {
            do {
                loaded.append(try Self.migrate(Data(contentsOf: file)))
            } catch {
                loadErrors.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        mixes = loaded.sorted { $0.slot < $1.slot }
    }

    /// Upgrades older files to the current schema. Version 1 is the first.
    private static func migrate(_ data: Data) throws -> Mix {
        try JSONDecoder().decode(Mix.self, from: data)
    }

    func mix(id: String) -> Mix? {
        mixes.first { $0.id == id }
    }

    @discardableResult
    func create(name: String, sources: [MixSource]) -> Mix? {
        let used = Set(mixes.map(\.slot))
        guard let slot = (0..<16).first(where: { !used.contains($0) }) else {
            return nil
        }
        let mix = Mix(id: MixSource.newID(), name: name, slot: slot, sources: sources)
        mixes.append(mix)
        mixes.sort { $0.slot < $1.slot }
        write(mix)
        onChange?(mixes)
        return mix
    }

    func update(_ mix: Mix) {
        guard let index = mixes.firstIndex(where: { $0.id == mix.id }), mixes[index] != mix else {
            return
        }
        mixes[index] = mix
        onChange?(mixes)
        scheduleWrite(mix.id)
    }

    /// A slider drag sends many updates a second; the file is written once it settles.
    @ObservationIgnored private var pendingWrites: [String: Task<Void, Never>] = [:]

    private func scheduleWrite(_ id: String) {
        pendingWrites[id]?.cancel()
        pendingWrites[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let mix = self.mix(id: id) else { return }
            self.write(mix)
            self.pendingWrites[id] = nil
        }
    }

    func delete(id: String) {
        pendingWrites[id]?.cancel()
        pendingWrites[id] = nil
        mixes.removeAll { $0.id == id }
        let file = url(for: id)
        try? FileManager.default.removeItem(at: backup(of: file))
        try? FileManager.default.moveItem(at: file, to: backup(of: file))
        onChange?(mixes)
    }

    /// Removes every mix and Blend's folder in Application Support, for uninstalling.
    func deleteAll() {
        for task in pendingWrites.values {
            task.cancel()
        }
        pendingWrites = [:]
        mixes = []
        onChange?(mixes)
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func write(_ mix: Mix) {
        let file = url(for: mix.id)
        do {
            let data = try encoder.encode(mix)
            if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: backup(of: file))
                try? FileManager.default.copyItem(at: file, to: backup(of: file))
            }
            try data.write(to: file, options: .atomic)
        } catch {
            loadErrors.append("Could not save \(mix.name): \(error.localizedDescription)")
        }
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private func backup(of file: URL) -> URL {
        file.appendingPathExtension("bak")
    }
}
