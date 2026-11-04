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
    var sources: [MixSource] = []
}
