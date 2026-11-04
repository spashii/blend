import Foundation

/// How much of Apple's voice isolation a microphone source gets.
enum Isolation: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case standard
    case highQuality = "high"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .standard: "Standard"
        case .highQuality: "High quality"
        }
    }
}

struct Processing: Codable, Hashable, Sendable {
    var echoCancel = false
    var isolation: Isolation = .off
}

struct MixSource: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case device
        case app
        /// Everything the Mac plays, except Blend and the apps using this mix, so an app on
        /// a call through the mix never hears itself.
        case system
    }

    var id: String = MixSource.newID()
    var kind: Kind
    /// Core Audio device UID, for devices.
    var uid: String?
    /// Bundle ID, for apps.
    var bundleID: String?
    /// One instance of an app that runs several, such as a Firefox profile's folder name.
    var instance: String?
    /// Shown in the UI, and used to find the same device again when a preset moves to
    /// another Mac where the UID differs.
    var name: String
    var gainDb: Double = 0
    var muted = false
    var processing = Processing()

    static func newID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    static func device(uid: String, name: String, processing: Processing = Processing()) -> MixSource {
        MixSource(kind: .device, uid: uid, name: name, processing: processing)
    }

    static func app(_ app: RunningApp) -> MixSource {
        MixSource(kind: .app, bundleID: app.bundleID, instance: app.instance, name: app.name)
    }

    static func system() -> MixSource {
        MixSource(kind: .system, name: "System audio")
    }
}

/// A preset: one named virtual microphone and everything it carries.
struct Mix: Codable, Hashable, Identifiable, Sendable {
    static let currentSchema = 1

    var schemaVersion = Mix.currentSchema
    var id: String
    var name: String
    /// Position on the driver's bus, 0 to 15. Fixed for the life of the mix.
    var slot: Int
    var gainDb: Double = 0
    var muted = false
    /// With exactly two sources: the first on the left channel only, the second on the
    /// right only, so a recorder can tell them apart. Ignored with any other number.
    var split = false
    /// A split ends when the mix stops having two sources, so adding a different second
    /// source later doesn't quietly split it again.
    var sources: [MixSource] = [] {
        didSet {
            if sources.count != 2 { split = false }
        }
    }

    var isSplit: Bool {
        split && sources.count == 2
    }

    /// "MacBook Air Microphone on the left, System audio on the right", for two sources.
    var splitDescription: String {
        guard sources.count == 2 else { return "" }
        return "\(sources[0].name) on the left, \(sources[1].name) on the right"
    }
}

extension Mix {
    /// Files written before a field existed decode with its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Mix.currentSchema
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        slot = try c.decode(Int.self, forKey: .slot)
        gainDb = try c.decodeIfPresent(Double.self, forKey: .gainDb) ?? 0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        split = try c.decodeIfPresent(Bool.self, forKey: .split) ?? false
        sources = try c.decodeIfPresent([MixSource].self, forKey: .sources) ?? []
    }
}
