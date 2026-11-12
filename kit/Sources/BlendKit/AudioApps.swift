import BlendKitCore
import Foundation

/// A running app, or one copy of it, that can be tapped.
public struct AudioApp: Sendable, Hashable, Identifiable {
    public let bundleID: String
    public let name: String
    public let pid: Int32
    /// Tells copies of one app apart, such as two browser profiles; nil for a plain launch.
    public let instance: String?
    /// A name that distinguishes this copy from the others of the same app.
    public let label: String
    /// Some process of this copy is producing sound right now.
    public let isPlaying: Bool
    /// Some process of this copy is using a microphone, as a call app does in a call.
    public let isListening: Bool

    public var id: String { instance.map { "\(bundleID)#\($0)" } ?? bundleID }

    public var target: TapTarget { TapTarget(bundleID: bundleID, instance: instance) }
}

public enum AudioApps {
    /// The regular apps that are running now. Reads the process list and each copy's launch
    /// arguments, which takes a moment: call it off the main thread.
    public static func running() -> [AudioApp] {
        guard let raw = BlendCopyRunningApps() else { return [] }
        defer { free(raw) }
        return parse(Data(bytes: raw, count: strlen(raw)))
    }

    static func parse(_ data: Data) -> [AudioApp] {
        struct Row: Decodable {
            var bundleID: String
            var name: String
            var pid: Int32
            var identity: String?
            var label: String?
            var playing: Bool?
            var listening: Bool?
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.map {
            AudioApp(
                bundleID: $0.bundleID, name: $0.name, pid: $0.pid,
                instance: $0.identity.flatMap { $0.isEmpty ? nil : $0 },
                label: $0.label ?? $0.name, isPlaying: $0.playing ?? false,
                isListening: $0.listening ?? false)
        }
    }
}

/// What to tap: an app by bundle ID, every audio process of its copies, or with an instance
/// only the copy launched with that identity (see `AudioApp.instance`).
public struct TapTarget: Sendable, Hashable {
    public var bundleID: String
    public var instance: String?

    public init(bundleID: String, instance: String? = nil) {
        self.bundleID = bundleID
        self.instance = instance
    }
}
