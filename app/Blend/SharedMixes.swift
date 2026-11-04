import Foundation

/// Every mix described for other apps, such as a recorder that keeps the two sides of a
/// split mix apart, at ~/Library/Application Support/Blend/devices.json. The format is in
/// docs/MIXES-FOR-APPS.md. Written only when it changes, which a volume change never does.
@MainActor
final class SharedMixes {
    private struct File: Encodable {
        var version = 1
        let mixes: [Entry]
    }

    private struct Entry: Encodable {
        let id: String
        let name: String
        let deviceUID: String
        let split: Bool
        let sources: [Source]
    }

    private struct Source: Encodable {
        let kind: String
        let name: String
        let uid: String?
        let bundleID: String?
        /// "left" or "right" in a split mix, "both" otherwise.
        let channel: String
    }

    private let url: URL
    private var written: Data?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(directory: URL? = nil) {
        url = (directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Blend", isDirectory: true))
            .appendingPathComponent("devices.json")
    }

    func write(_ mixes: [Mix]) {
        let file = File(mixes: mixes.map { mix in
            Entry(id: mix.id, name: mix.name, deviceUID: "app.blend.mix." + mix.id,
                split: mix.isSplit,
                sources: mix.sources.enumerated().map { index, source in
                    Source(kind: source.kind.rawValue, name: source.name, uid: source.uid,
                        bundleID: source.bundleID,
                        channel: mix.isSplit ? (index == 0 ? "left" : "right") : "both")
                })
        })
        guard let data = try? encoder.encode(file), data != written else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            written = data
        } catch {
            // Other apps fall back to finding the mix by name; nothing in Blend depends on it.
        }
    }
}
